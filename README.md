# COBRA Battery Recycling Network Model

COBRA models the retirement, collection, recycling and logistics of vehicle batteries in China, and optimizes recycling capacity and material flows across cities.

The current release is v6.0.0. It covers six battery chemistries: LFP, LMO, NCM-L, NCM-M, NCM-H and NCA. Packaged inputs support factory cost and emission assessment and a six-point cost–emission frontier.

## Quick Start

1. Open this repository in MATLAB R2025b on Windows. For optimization, install licensed AMPL and its Gurobi solver driver, with `ampl.exe` and `gurobi.exe` available on PATH.
2. Calculate the default assessment and prepare the optimization files:

```matlab
addpath('scripts');
[outflow, assessment_result, logistics_result, optimization_result, folder] = ...
    run_scenario();
```

This step does not run the solver. `optimization_result` is empty; `folder` identifies the generated AMPL working directory.

3. To solve the default network, run:

```matlab
[outflow, assessment_result, logistics_result, optimization_result, folder] = ...
    run_scenario([], solve=true);
```

4. Read the saved results:

```text
outputs/assessment_result.mat
outputs/optimization_result.mat
```

Both use MAT v7.3. The assessment is saved on each run; the optimization result is saved after successful solving. Repeated runs overwrite these filenames. A preparation-only run leaves any previous optimization result unchanged.

## Prepare Input

The repository includes six MAT inputs. Each file contains a variable with the same name as the file:

| File | Content |
| --- | --- |
| `inputs/retirement.mat` | Battery inflow, energy density, retirement and collection assumptions. |
| `inputs/recovery.mat` | Recycling intensities, learning floors and factory parameters. |
| `inputs/logistics.mat` | Transport and storage intensities, distances and operating assumptions. |
| `inputs/cost_factor.mat` | Unit prices, fees and currency conversion. |
| `inputs/emission_factor.mat` | Material, utility, waste and electricity-grid emission factors. |
| `inputs/optimization.mat` | Candidate cities, initial capacity, model constraints and solver settings. |

Inputs remain read-only during execution. Scenario overrides are applied in memory, and city data are matched by name before numerical arrays are bound to the optimization model. The original reference workbooks and historical research archive are not required at runtime.

## Run a Scenario

The default configuration is `configs/scenario.mat`. It uses a brownfield network and the window `[2025; 2040]`: 2025 is the base year, and decision years are 2026–2040.

To change a scenario without editing the inputs:

```matlab
s = load('configs/scenario.mat', 'scenario');
scenario = s.scenario;
scenario.learning_rate = 0.10;
scenario.grid_case = "S5";

[outflow, assessment_result, logistics_result, optimization_result, folder] = ...
    run_scenario(scenario, solve=true);
```

Keep the configuration's nine fields:

| Field | Meaning |
| --- | --- |
| `window` | Column vector `[start; end]`; optimization covers `(start, end]`. |
| `mode` | `brownfield` or `greenfield`. |
| `median_life` | Median battery life in years. |
| `collection_rate_2040` | Formal collection fraction in 2040. |
| `learning_rate` | Reduction in the remaining base-to-floor gap per experience doubling. |
| `transport_multiplier` | Transport cost multiplier. |
| `electric_share_2040` | Electric-truck share in 2040. |
| `metal_price_case` | `low`, `base` or `high` for the linked metal and battery prices. |
| `grid_case` | Electricity-grid emission case, such as `S1`, `S4` or `S5`. |

Learning uses LFP and non-LFP experience pools, includes baseline experience accumulated before 2025, and uses experience through the preceding year. Accounting supports years through 2060.

For executables outside PATH, pass `ampl="C:/path/to/ampl.exe"` and `solver="C:/path/to/gurobi.exe"` to `run_scenario`. To retain solver files in a chosen directory, pass `folder="outputs/baseline_work"`; the directory must be new or empty. Otherwise a new system temporary directory is used. The current solver launcher requires Windows.

## Read Output

| Result | Meaning and units |
| --- | --- |
| `outflow.mass` | Collected battery packs, tonnes; city × year × chemistry. |
| `assessment_result.RC` | Factory cost, USD/tonne of battery packs; city × year × chemistry. |
| `assessment_result.RE` | Factory emissions, tonnes CO₂e/tonne of battery packs; city × year × chemistry. |
| `logistics_result.cost` | Logistics cost, USD/tonne of battery packs; origin × destination × year. |
| `logistics_result.emission` | Logistics emissions, tonnes CO₂e/tonne of battery packs; origin × destination × year. |
| `optimization_result` | Scenario coordinates, six-point objective summary and network solutions. |

`RC` retains the ten components `PT`, `LD`, `RM`, `UT`, `WD`, `LB`, `MT`, `IS`, `RD` and `GA`. It is gross factory processing cost, excluding battery purchase and logistics and without subtracting product revenue. `RE` retains `PC` (process and energy), `UM` (upstream materials) and `WT` (waste treatment).

The network cost objective is discounted to 2025; its physical emission objective is not discounted. Year, chemistry and window coordinates are column vectors. Outflow and logistics results are returned in memory; only the two named result files are saved automatically.

## Optimization Settings

The model first solves minimum-cost and minimum-emission reference endpoints. It then minimizes cost under a cap of `min(cost_endpoint_emission, minimum_emission_reference × 1.0001)`, followed by four interior emission budgets. The final output has six points. The endpoint's 0.01% emission allowance is separate from the 0.01% MIPGap.

Formal solver settings are stored in `inputs/optimization.mat`. The default is up to four concurrent tasks with four threads per task. The implementation retains the verified endpoint starting solution and equivalent constraint strengthening. AMPL, Gurobi and their licenses must be supplied separately.

## Repository Contents

- `inputs/`: packaged model intensities, parameters, prices and emission factors.
- `configs/scenario.mat`: default scenario overrides and selectors.
- `src/`: retirement, recovery, logistics and optimization functions, plus the AMPL model.
- `scripts/`: `run_scenario.m`, `run_assessment.m` and `run_optimization.m`.
- `outputs/`: generated results; initially contains only `.gitkeep`.
- `.gitignore`, `LICENSE` and `README.md`: generated-file exclusions, license and usage entrypoint.

The core was checked against the frozen version used in the completed 60-scenario study. Migration checks confirmed unchanged core files and matching accounting results. Historical analyses, scenario-search scripts, original reference documents and stored research results are maintained separately. These checks establish reproducibility, not independent validation of all engineering assumptions or proof of global scenario bounds.

## License

[Apache License 2.0](LICENSE). The license covers the code and documentation; third-party data and source materials retain their own rights.
