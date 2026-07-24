defmodule Number42.Refactors.Detection.Finding do
  @moduledoc """
  One candidate site located by a detector: what was found, where it is,
  the evidence that triggered it, and whether the gate accepted it.

  A finding is a **fact plus a verdict**, and deliberately not a plan. It
  says "this looks like an under-componentised subtree, here, and here is
  why I think so" — it does not say what the replacement should be. That
  is Suggestion's job.

  ## Why evidence and gating are first-class

  Detectors gate on thresholds (minimum mass, maximum leak, occurrence
  counts). Historically those gates lived inside `transform/2`, so a
  rejected candidate left no trace: you could not tell "found nothing"
  apart from "found something and declined it". A finding records both,
  which is what makes it reviewable and what a calibrated gate can later
  tune against.

  `accepted?` is the gate's verdict. When it is `false`, `decline` carries
  the human-readable reason, and the finding is still returned — a
  declined finding is a diagnostic, not a discard.

  ## Fields

  - `:refactor` — the module whose detector produced this finding.
  - `:kind` — detector-local classification of the smell (`:eex_block`,
    `:exact_duplicate`, `:parameter_train`, …). Detectors define their own
    vocabulary; this is not a closed set.
  - `:path` — file the site lives in, when known. `nil` for detectors run
    against a bare source string with no path context.
  - `:line` — 1-based line of the site, when known.
  - `:range` — byte range `{start, stop}` of the site, when the detector
    can pin it exactly. Only some detectors can.
  - `:scope` — the enclosing module and/or function, when known:
    `%{module: module() | nil, function: {atom(), arity()} | atom() | nil}`.
  - `:evidence` — the measurements the gate ran on, as a plain map (e.g.
    `%{nodes: 9, lines: 21, leak: 0.1}`). This is Analysis output, carried
    forward so a reader can see *why* without re-running the analysis.
  - `:confidence` — normalised `0.0..1.0` gate strength when the detector
    has a meaningful score, `nil` when its gate is a hard threshold with
    no notion of degree. Do not invent a number to fill this in.
  - `:accepted?` — whether the gate accepted the site.
  - `:decline` — reason the gate rejected it; `nil` when accepted.
  - `:description` — one-line human-readable summary of the site.
  """

  @type scope :: %{
          optional(:module) => module() | nil,
          optional(:function) => {atom(), arity()} | atom() | nil
        }

  @type t :: %__MODULE__{
          accepted?: boolean(),
          confidence: float() | nil,
          decline: String.t() | nil,
          description: String.t() | nil,
          evidence: map(),
          kind: atom(),
          line: pos_integer() | nil,
          path: String.t() | nil,
          range: {non_neg_integer(), non_neg_integer()} | nil,
          refactor: module() | nil,
          scope: scope()
        }

  defstruct accepted?: true,
            confidence: nil,
            decline: nil,
            description: nil,
            evidence: %{},
            kind: nil,
            line: nil,
            path: nil,
            range: nil,
            refactor: nil,
            scope: %{}

  @doc """
  Build an accepted finding of the given `kind`.

  Remaining fields come from `attrs`, using the same keys as the struct.
  """
  @spec accept(atom(), keyword() | map()) :: t()
  def accept(kind, attrs \\ []) do
    build(kind, attrs, accepted?: true, decline: nil)
  end

  @doc """
  Build a declined finding of the given `kind`, carrying `reason`.

  Declined findings are returned like any other — they are the diagnostic
  record of a gate firing, not a discard.
  """
  @spec decline(atom(), String.t(), keyword() | map()) :: t()
  def decline(kind, reason, attrs \\ []) do
    build(kind, attrs, accepted?: false, decline: reason)
  end

  @doc "Keep only the findings whose gate accepted them."
  @spec accepted([t()]) :: [t()]
  def accepted(findings), do: findings |> Enum.filter(& &1.accepted?)

  @doc "Keep only the findings whose gate rejected them."
  @spec declined([t()]) :: [t()]
  def declined(findings), do: findings |> Enum.reject(& &1.accepted?)

  @doc """
  Group findings by `:path`, dropping those with no path context.

  Detectors run over a corpus emit a flat list; the per-file layers
  (`transform/2`, a diagnostic report) want them keyed by file.
  """
  @spec by_path([t()]) :: %{String.t() => [t()]}
  def by_path(findings) do
    findings
    |> Enum.reject(&is_nil(&1.path))
    |> Enum.group_by(& &1.path)
  end

  @doc """
  Render a finding as a single diagnostic line.

      lib/my_app_web/live/page.ex:42 [eex_block] declined: seam leaks 3 vars
  """
  @spec to_line(t()) :: String.t()
  def to_line(%__MODULE__{} = finding) do
    [location(finding), "[#{finding.kind}]", verdict(finding)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp build(kind, attrs, verdict) do
    fields = attrs |> Map.new() |> Map.merge(Map.new(verdict))

    struct!(__MODULE__, Map.put(fields, :kind, kind))
  end

  defp location(%__MODULE__{path: nil}), do: ""
  defp location(%__MODULE__{path: path, line: nil}), do: path
  defp location(%__MODULE__{path: path, line: line}), do: "#{path}:#{line}"

  defp verdict(%__MODULE__{accepted?: false, decline: reason}) when is_binary(reason),
    do: "declined: #{reason}"

  defp verdict(%__MODULE__{accepted?: false}), do: "declined"
  defp verdict(%__MODULE__{description: nil}), do: "accepted"
  defp verdict(%__MODULE__{description: description}), do: description
end
