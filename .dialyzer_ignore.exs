# Dialyzer ignore list.
#
# Each entry is a `{relative_path, warning_type}` tuple (dialyxir 1.4
# format). Per-file/per-type tuples are used instead of copied warning
# strings so the list stays robust against line shifts and message
# wording changes while still scoping every skip to a single file and a
# single warning class.
#
# Two — and only two — categories are silenced here. Both are upstream /
# tooling limitations, not defects in this codebase; every real,
# project-local finding is fixed in the source instead.

[
  # ---------------------------------------------------------------------------
  # Category A — Sourceror.Patch.replace/2 spec gap (deps/sourceror).
  #
  # `Sourceror.Patch.replace/2` has two clauses but only one is covered by
  # its @spec:
  #
  #     @spec replace(Sourceror.Zipper.t(), String.t()) :: Sourceror.Patch.t()
  #     def replace(%Zipper{} = zipper, replacement), do: ...
  #     def replace(ast_node, replacement) do ... end   # not in the @spec
  #
  # Every refactor calls the second (raw-AST) clause with an AST tuple plus a
  # string. Dialyzer checks the call against the narrow @spec (%Zipper{} only)
  # and reports `:call` "will not succeed". Because that call is then typed as
  # `none()`, the surrounding wrappers inherit poisoned success typings, which
  # surfaces as the follow-on `:pattern_match`, `:pattern_match_cov` and
  # `:no_return` findings in the same walk functions.
  #
  # The n42 code is functionally correct (the runtime clause exists and is
  # exercised by the test suite); the contract in the dependency is simply
  # incomplete. We silence the noise per file/type rather than touching the
  # dependency or rewriting every refactor onto the Zipper API.
  {"lib/number42/refactors/ex/case_to_function_clauses.ex", :call},
  {"lib/number42/refactors/ex/case_true_false.ex", :call},
  {"lib/number42/refactors/ex/collapse_nested_case_to_with.ex", :call},
  {"lib/number42/refactors/ex/debug_inspect_cleanup.ex", :call},
  {"lib/number42/refactors/ex/enum_capture.ex", :call},
  {"lib/number42/refactors/ex/enum_capture.ex", :pattern_match},
  {"lib/number42/refactors/ex/enum_find_to_keyfind.ex", :call},
  {"lib/number42/refactors/ex/enum_into_to_map_new.ex", :call},
  {"lib/number42/refactors/ex/enum_map_into_to_map_new.ex", :call},
  {"lib/number42/refactors/ex/enum_reduce_to_sum.ex", :call},
  {"lib/number42/refactors/ex/enum_reverse_concat.ex", :call},
  {"lib/number42/refactors/ex/flat_map_to_filter.ex", :call},
  {"lib/number42/refactors/ex/graphemes_length.ex", :call},
  {"lib/number42/refactors/ex/identity_passthrough.ex", :call},
  {"lib/number42/refactors/ex/if_else_to_cond.ex", :call},
  {"lib/number42/refactors/ex/if_lift_to_clauses.ex", :call},
  {"lib/number42/refactors/ex/inline_single_expression_def.ex", :call},
  {"lib/number42/refactors/ex/length_in_guard.ex", :call},
  {"lib/number42/refactors/ex/length_in_guard.ex", :pattern_match_cov},
  {"lib/number42/refactors/ex/length_zero_to_empty.ex", :call},
  {"lib/number42/refactors/ex/lift_with_into_pipeline.ex", :call},
  {"lib/number42/refactors/ex/list_last_of_reverse.ex", :call},
  {"lib/number42/refactors/ex/manual_tap_to_tap.ex", :call},
  {"lib/number42/refactors/ex/map_get_unsafe_pass.ex", :call},
  {"lib/number42/refactors/ex/map_new_lambda_to_for_comprehension.ex", :call},
  {"lib/number42/refactors/ex/map_new_lambda_to_for_comprehension.ex", :no_return},
  {"lib/number42/refactors/ex/map_new_to_pipe.ex", :call},
  {"lib/number42/refactors/ex/map_sum_to_sum_by.ex", :call},
  {"lib/number42/refactors/ex/merge_pipeline_into_comprehension.ex", :call},
  {"lib/number42/refactors/ex/negated_boolean_name.ex", :call},
  {"lib/number42/refactors/ex/pipe_reassign.ex", :call},
  # `push_param_into_callee.ex` calls `Patch.replace` in
  # `rewrite_callee_clause/2` and `call_site_patch/4`; the `:call` plus the
  # two `:no_return` findings (the anonymous mapper and `rewrite_callee_clause/2`)
  # are pure follow-ons from the spec gap above.
  {"lib/number42/refactors/ex/push_param_into_callee.ex", :call},
  {"lib/number42/refactors/ex/push_param_into_callee.ex", :no_return},
  {"lib/number42/refactors/ex/reduce_as_map.ex", :call},
  {"lib/number42/refactors/ex/reduce_map_put.ex", :call},
  {"lib/number42/refactors/ex/redundant_boolean_if.ex", :call},
  {"lib/number42/refactors/ex/reject_is_nil.ex", :call},
  {"lib/number42/refactors/ex/remove_trivial_else_clause.ex", :call},
  {"lib/number42/refactors/ex/resolve_impl_true.ex", :call},
  {"lib/number42/refactors/ex/sort_for_top_k.ex", :call},
  {"lib/number42/refactors/ex/try_rescue_with_safe_alternative.ex", :call},
  {"lib/number42/refactors/ex/use_map_join.ex", :call},
  {"lib/number42/refactors/ex/utc_now_truncate.ex", :call},
  {"lib/number42/refactors/ex/with_single_clause_to_case.ex", :call},
  {"lib/number42/refactors/ex/with_without_else.ex", :call},
  {"lib/number42/refactors/ex/extract_cond_to_guard_clauses.ex", :call},
  {"lib/number42/refactors/ex/extract_socket_to_pipe.ex", :call},
  {"lib/number42/refactors/ex/extract_socket_to_pipe.ex", :pattern_match},
  {"lib/number42/refactors/ex/extract_to_pipeline.ex", :call},
  {"lib/number42/refactors/ex/extract_to_pipeline.ex", :pattern_match},
  # `unused_variable.ex` calls `Patch.replace` in `rename_patch/1`; the `:call`
  # and the two `:no_return` findings (the anonymous mapper and `rename_patch/1`
  # itself) are pure follow-ons from the spec gap above. The `:call_without_opaque`
  # in the same file is a separate, MapSet-opacity issue handled in Category B.
  {"lib/number42/refactors/ex/unused_variable.ex", :call},
  {"lib/number42/refactors/ex/unused_variable.ex", :no_return},

  # ---------------------------------------------------------------------------
  # Category B — MapSet opaqueness false positives (OTP/Dialyzer limitation).
  #
  # `MapSet.t()` is an opaque type. These functions build a MapSet locally
  # (e.g. from `MapSet.new/0,1`, a compile-time `@stop_words` literal, or
  # `MapSet.union/2`) and then immediately consume it via `MapSet.member?/2`
  # or `MapSet.union/2` in the same module. Dialyzer's success typing pins the
  # concrete internal representation (`%MapSet{map: {:set, ...}}` for non-empty
  # and `%MapSet{map: %{}}` for empty) and then reports `call_without_opaque`
  # when that concrete value crosses back into a function whose spec/inference
  # expects the opaque `MapSet.internal(_)`.
  #
  # The values genuinely are `MapSet`s and the code is correct. The only
  # "fixes" are either a project-wide `:no_opaque` flag (which would mask real
  # opacity bugs in the dependent feature PRs) or annotating the builders with
  # `@spec ... :: MapSet.t()` — which instead produces a `contract_with_opaque`
  # error because the success typing builds the struct concretely. Neither is a
  # clean, low-risk change, so these specific findings are scoped out per file.
  {"lib/number42/refactors/block_segmentation.ex", :call_without_opaque},
  {"lib/number42/refactors/ex/expand_short_form_functions.ex", :call_without_opaque},
  {"lib/number42/refactors/ex/extract_parametric_clone.ex", :call_without_opaque},
  {"lib/number42/refactors/ex/extract_renamed_clone.ex", :call_without_opaque},
  {"lib/number42/refactors/ex/extract_shared_module.ex", :call_without_opaque},
  {"lib/number42/refactors/ex/unused_variable.ex", :call_without_opaque},

  # ---------------------------------------------------------------------------
  # Category C — dev-only generator deps absent from the PLT.
  #
  # `mix n42.gen.predicate_model` is a dev-only Mix task (under `dev/`, only
  # compiled for `Mix.env() == :dev`). It calls `Tokenizers`, `Safetensors`
  # and `Nx`, which are declared `only: :dev, runtime: false` in mix.exs — so
  # the task can build the frozen model JSON locally, but those apps are never
  # part of a normal build and are absent from the Dialyzer PLT. Dialyzer then
  # reports every call into them as `unknown_function`. The runtime never runs
  # this task or loads these deps (it reads the committed JSON); the task is
  # exercised by hand when regenerating the model. Scope the noise to the file.
  {"dev/mix/tasks/n42.gen.predicate_model.ex", :unknown_function}
]
