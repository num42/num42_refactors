defmodule Number42.Refactors.Detection do
  @moduledoc """
  Behaviour for detectors: they consume `Number42.Refactors.Analysis`
  output, locate candidate sites, and emit
  `Number42.Refactors.Detection.Finding` structs.

  Detection sits between Analysis (pure measurement, no opinions) and
  Suggestion (decides and names the concrete change). A detector's whole
  job is *locating and classifying* — it never rewrites, never writes to
  disk, and never decides what the replacement looks like.

  Run on its own, this layer is a linter: it flags sites and changes
  nothing. That is the point, and it is what `mix refactor --detect`
  exposes.

  ## The contract

  A detector implements one of two entry points, depending on whether it
  can decide from a single file or needs the corpus:

  - `detect/2` — per-source detection. Gets one source string (plus opts
    carrying `:path` when known) and returns findings for that file.
  - `detect_corpus/2` — cross-file detection. Gets `{path, source}` pairs
    and returns findings across all of them. Clone families, duplicate
    functions and shared-module extraction need this; they cannot decide
    from one file.

  At least one must be implemented. A detector that implements only
  `detect/2` is automatically corpus-capable via `detect_corpus/2`'s
  default, which maps `detect/2` over each source. The reverse does not
  hold: a genuinely cross-file detector has no meaningful single-file
  answer, so it implements `detect_corpus/2` only.

  ## Purity

  Detectors must be **side-effect free**. They may read files handed to
  them via paths, but they must not write, must not touch the network,
  and must not depend on wall-clock or randomness. Two runs over the same
  corpus must produce the same findings in the same order — the diagnostic
  mode and the calibration work both rely on that.

  Ordering must be deterministic. Sort by `{path, line}` (or another total
  order) before returning; do not leak `Task.async_stream` completion
  order into the result.

  ## Gating

  A detector gates candidates and reports **both** verdicts. Use
  `Finding.accept/2` and `Finding.decline/3`; return declined findings
  rather than dropping them, so a reader can tell "nothing here" apart
  from "something here that I rejected, for this reason".

  ## Wiring a detector to a refactor

  A refactor names its detector via the optional `detector/0` callback on
  `Number42.Refactors.Refactor`. The engine can then run detection without
  instantiating the transform:

      defmodule MyRefactor do
        use Number42.Refactors.Refactor

        @impl Number42.Refactors.Refactor
        def detector, do: MyRefactor.Detector
      end

  A refactor may also *be* its own detector by implementing this behaviour
  directly and returning `__MODULE__`.
  """

  alias Number42.Refactors.Detection.Finding

  @doc """
  Locate candidate sites in a single source.

  `opts` carries the per-module configuration, plus `:path` when the
  caller knows which file the source came from — set it whenever possible,
  since findings without a path cannot be grouped per file.

  Returns a deterministically-ordered list of findings, including declined
  ones. An empty list means "nothing resembling this smell here".
  """
  @callback detect(source :: String.t(), opts :: keyword()) :: [Finding.t()]

  @doc """
  Locate candidate sites across a corpus of `{path, source}` pairs.

  Implement this for detectors whose decision is inherently cross-file
  (clone families, duplicate functions, shared-module extraction). For
  per-file detectors this is derived from `detect/2` and needs no
  implementation.
  """
  @callback detect_corpus(sources :: [{String.t(), String.t()}], opts :: keyword()) ::
              [Finding.t()]

  @doc """
  One-line description of what this detector looks for.

  Defaults to the host refactor's `description/0` when the detector is the
  refactor module itself.
  """
  @callback detects() :: String.t()

  @optional_callbacks detect: 2, detect_corpus: 2, detects: 0

  @doc """
  Marks the using module as a detector and supplies the derived
  `detect_corpus/2`.

  The injected `detect_corpus/2` maps `detect/2` over each `{path, source}`
  pair, threading the path into opts so findings carry their file. It is
  overridable — a cross-file detector defines its own.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Number42.Refactors.Detection

      # The zero-opts head lives separately from `detect_corpus/2` rather
      # than as a default argument: an overriding module defines only
      # `detect_corpus/2`, and a default arg there would clash with this
      # injected clause ("previous clause always matches").
      def detect_corpus(sources), do: detect_corpus(sources, [])

      @impl Number42.Refactors.Detection
      def detect_corpus(sources, opts) do
        sources
        |> Enum.sort_by(fn {path, _source} -> path end)
        |> Enum.flat_map(fn {path, source} ->
          detect(source, Keyword.put(opts, :path, path))
        end)
      end

      defoverridable detect_corpus: 1, detect_corpus: 2
    end
  end

  @doc """
  Run `module`'s detection over a corpus, using whichever entry point it
  implements.

  Prefers `detect_corpus/2`; falls back to mapping `detect/2` when only
  the per-source callback exists. Raises when the module implements
  neither, since that is a wiring mistake rather than an empty result.
  """
  @spec run(module(), [{String.t(), String.t()}], keyword()) :: [Finding.t()]
  def run(module, sources, opts \\ []) do
    # Load before probing: `function_exported?/3` answers `false` for a
    # module that simply has not been loaded yet, which would silently
    # look like "detector implements neither entry point".
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :detect_corpus, 2) ->
        module.detect_corpus(sources, opts)

      function_exported?(module, :detect, 2) ->
        sources
        |> Enum.sort_by(fn {path, _source} -> path end)
        |> Enum.flat_map(fn {path, source} ->
          module.detect(source, Keyword.put(opts, :path, path))
        end)

      true ->
        raise ArgumentError,
              "#{inspect(module)} implements neither detect/2 nor detect_corpus/2"
    end
  end

  @doc """
  Whether `module` can act as a detector.

  True when it exports either detection entry point. Used by the engine to
  decide whether a refactor's declared detector is runnable.
  """
  @spec detector?(module()) :: boolean()
  def detector?(module) do
    Code.ensure_loaded?(module) and
      (function_exported?(module, :detect, 2) or function_exported?(module, :detect_corpus, 2))
  end
end
