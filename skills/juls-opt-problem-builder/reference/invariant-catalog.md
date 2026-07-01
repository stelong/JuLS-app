# Invariant catalog

The building blocks you assemble into a `create_dag(e)` function. Each is a node
added with `add_invariant!(dag, <Invariant>; ...)`. Parents are given as either
`variable_parent_indexes` (decision-variable roots, 1-based) or
`invariant_parent_indexes` (other nodes, by the id `add_invariant!` returns).
Optional kwargs: `name` (for readable output) and `using_cp=true` (expose the node
to the constraint-programming move filter). Grounded in `src/experiments/*/*_dag.jl`.

| Invariant | Computes | Typical use |
| --- | --- | --- |
| `ScaleInvariant(c)` | `c * parent` | Weight/scale one variable: value `ScaleInvariant(-value[i])`, weight `ScaleInvariant(weight[i])`. Negative coefficient = maximize that term. |
| `ObjectiveInvariant()` | sum of its parents, tagged as the objective | The single node the solver minimizes; parent it to all cost terms. |
| `AggregatorInvariant()` | sum of its parents | Combine objective with penalized constraints into the final root; also used to sum groups of terms. |
| `ComparatorInvariant(bound)` | violation of `sum(parents) ≤ bound` (0 if satisfied) | Capacity / budget / resource limits. |
| `StaticConstraintInvariant(α)` | `α * violation` | Turn a raw violation into a penalty added to the objective. Larger `α` = harder constraint. |
| `ElementInvariant(i, table)` | `table[value_of_variable_i]` | Map an integer decision to a precomputed cost, e.g. squared deviation per level. Lets nonlinear per-variable costs stay incremental (a table lookup). |
| `AggregatorInvariant` over per-element nodes | grouped sums | Sum contributions per group (e.g. load per plant, count per color). |

Notes and conventions:
- **Objective vs. penalty split.** Cost terms flow into `ObjectiveInvariant`;
  constraint violations flow `... → ComparatorInvariant → StaticConstraintInvariant`.
  A final `AggregatorInvariant([constraint_node, objective_node])` is the DAG root.
  `isfeasible` is true when the total violation is zero.
- **`using_cp=true`** on the nodes that encode a hard constraint (e.g. the weight
  and capacity nodes in knapsack) lets the CP filter prune infeasible moves before
  they are evaluated — faster search, but optional.
- **Nonlinearity → lookup tables.** Local search never needs a closed-form
  gradient. Any per-variable nonlinear cost (quadratic deviation, tiered price,
  step function) becomes an `ElementInvariant` over a precomputed vector, so a move
  is still an O(1) table lookup + incremental re-sum.
- **The canonical shape** (see `src/experiments/knapsack/knapsack_dag.jl`):

  ```
  variables ──ScaleInvariant(-value)──┐
                                      ├─ ObjectiveInvariant ─┐
  variables ──ScaleInvariant(weight)─→ ComparatorInvariant  │
                                        → StaticConstraintInvariant(α) ─┤
                                                          AggregatorInvariant  ← DAG root
  ```

Read the real builders for patterns:
- `src/experiments/knapsack/knapsack_dag.jl` — capacity + linear objective (binary).
- `src/experiments/production_planning/*` — per-plant `ElementInvariant` quadratic
  deviation, capacity constraint (integer levels).
- `src/experiments/graph_coloring/*` — conflict counting over edges (integer category).
