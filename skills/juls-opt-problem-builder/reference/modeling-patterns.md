# Modeling patterns: math construct → JuLS building blocks

Look up each objective term and constraint of the user's problem here, and explain
the mapping to them. The recurring principle: **decompose so that flipping one
variable touches as few nodes as possible** — that is what makes CBLS fast.

## Decision variables → `decision_type` + `generate_domains`

| Math | `decision_type` | `generate_domains(e)` |
| --- | --- | --- |
| binary `xᵢ ∈ {0,1}` (select / on-off) | `BinaryDecisionValue` | `[[false, true] for _ in 1:n]` |
| integer level `xᵢ ∈ {1..K}` (amount, tier, category) | `IntDecisionValue` | `[collect(1:K) for _ in 1:n]` |
| one category/color `xᵢ ∈ {1..C}` | `IntDecisionValue` | `[collect(1:C) for _ in 1:n]` |
| permutation / tour | `IntDecisionValue` over positions | see `tsp` (structure-specific) |

The decision shape also picks the neighbourhood: default
`ExhaustiveNeighbourhood(2, n)` flips up to 2 variables; graph problems use a
structure-aware sampler (`graph_coloring`).

## Objective terms

| Objective term | Building blocks | Why |
| --- | --- | --- |
| linear `Σ cᵢ xᵢ` (maximize) | `ScaleInvariant(-cᵢ)` per var → `ObjectiveInvariant` | negate to minimize; each term is one node |
| linear `Σ cᵢ xᵢ` (minimize) | `ScaleInvariant(cᵢ)` per var → `ObjectiveInvariant` | direct |
| quadratic deviation `Σ (xᵢ − tᵢ)²` | precompute `table_i = [(v − tᵢ)² for v in domain]`; `ElementInvariant(i, table_i)` → `ObjectiveInvariant` | nonlinear cost becomes an O(1) lookup, stays incremental |
| tiered / piecewise cost of `xᵢ` | `ElementInvariant(i, cost_table_i)` | any per-variable function is a table |
| count of a property (e.g. #conflicts) | per-relation invariant → `AggregatorInvariant` → `ObjectiveInvariant` | sum contributions incrementally |

## Constraints (each becomes a penalty)

| Constraint | Building blocks | Why |
| --- | --- | --- |
| capacity / budget `Σ wᵢ xᵢ ≤ C` | `ScaleInvariant(wᵢ)` per var → `ComparatorInvariant(C)` → `StaticConstraintInvariant(α)` | comparator measures overflow; α penalizes it |
| lower bound `Σ … ≥ L` | rewrite as `−Σ … ≤ −L` (negate into a comparator) | comparators test `≤` |
| equality `Σ … = C` | two comparators (`≤ C` and `≥ C`) summed, or a squared-deviation objective term | penalize both directions |
| resource per group (e.g. load ≤ cap **per plant**) | group vars with `AggregatorInvariant` per group → `ComparatorInvariant(cap)` each → `StaticConstraintInvariant(α)` | one penalty branch per group |
| conflict / all-different (`xᵢ ≠ xⱼ` for edges) | per-edge equality-count invariant → aggregate → penalty (see `graph_coloring`) | penalize each violated pair |

Then a single `AggregatorInvariant([<all penalty nodes>, objective_node])` is the
DAG root. Feasible ⇔ every `StaticConstraintInvariant` contributes 0.

## Choosing the penalty `α`
`α` trades feasibility against objective. Too small: the solver "buys out" of a
constraint by paying the penalty. Too large: it over-focuses on feasibility and
gets stuck. Start with `α` on the order of the objective's magnitude per unit of
violation; the built-ins expose it as an optional `penalty` field with a default
(`DEFAULT_PENALTY_PARAM`). Make it a `data_schema` field so callers can tune it.

## Worked mini-example (capacity + linear value, i.e. knapsack)
- vars: binary `xᵢ`; `generate_domains = [[false,true] for _ in 1:n]`.
- objective (maximize value): `ScaleInvariant(-valueᵢ)` → `ObjectiveInvariant`.
- constraint (weight ≤ C): `ScaleInvariant(weightᵢ)` → `ComparatorInvariant(C)` →
  `StaticConstraintInvariant(α)`.
- root: `AggregatorInvariant([constraint_node, objective_node])`.

Read `src/experiments/knapsack/knapsack_dag.jl` alongside this — it is exactly the
above in code.
