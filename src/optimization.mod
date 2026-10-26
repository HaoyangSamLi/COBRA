# Standard linear mixed-integer formulation, no solve/run/presolve commands.
# Public units: tonnes, t/year capacity, USD, t CO2e. No numerical rescaling.
# Data binding and solver execution are intentionally outside this file.

set city ordered;
set chemistry ordered;
param base_year integer; # inputs/optimization.parameter, currently 2025.
param year_start integer >= base_year; # window left endpoint, excluded.
param year_end integer > year_start;   # window right endpoint, included.
set year := (year_start+1)..year_end;
set vintage := {base_year} union year;

# Config controls. The caller selects a mode and one absolute emission budget.
# mip_gap belongs to solver execution, not to the mathematical problem.
# inputs/optimization.parameter contains epsilon and mip_gap.
# epsilon is the normalized frontier STEP, not this absolute budget.
param mode symbolic in {"greenfield", "brownfield"};
param throughput_share_max > 0 <= 1;
param use_epsilon binary;
param emission_limit >= 0;

# optimization.city provides actor; optimization.capacity provides initial
# capacity. Both tables are joined by city row names, never regenerated.
param actor {city} binary;
set candidate ordered := {j in city: actor[j]=1};
param initial_capacity {city,chemistry} >= 0;
param outflow {city,year,chemistry} >= 0;
param life integer > 0; # recovery.parameter economic_life (currently 20).
# Agreed proxy: existing stock has the same remaining life as a new factory,
# counted from start of base_year+1. No duplicate input is stored.
param existing_life := life;
# Automatic algebraic branch, not a scenario option or decision variable.
# New capacity can expire only after the earliest possible commissioning year.
# Stock already expired before the window contributes zero in either branch.
param has_expiry binary :=
    (if year_end>=year_start+1+life
     || (mode="brownfield"
         && sum {j in city,k in chemistry} initial_capacity[j,k]>0
         && year_start+1<base_year+1+existing_life
         && year_end>=base_year+1+existing_life)
     then 1 else 0);
set operating_vintage {t in year} :=
    (if has_expiry=1 then {v in year: v<=t && t<v+life}
     else {v in year: v<=t});
param minimum_capacity >= 0; # t/year; current input 5000 (0.5 ten-thousand t/year).
# Independent evaluation rate from optimization.parameter discount_rate (0.05).
# Never inherit the factory, transport or storage annualization rates.
# Annual costs occur at year-end and are discounted to end of base_year.
param discount_rate >= 0;
param discount_cost binary;
param DF {t in year} :=
    (if discount_cost=1 then (1+discount_rate)^(-(t-base_year)) else 1);
param capacity0 {j in city,t in year,k in chemistry} :=
    (if mode="greenfield" || year_start+1>=base_year+1+existing_life then 0
     else if has_expiry=0 then initial_capacity[j,k]
     else if t<base_year+1+existing_life then initial_capacity[j,k] else 0);

# Original cost names. 2025 values proxy existing asset design coefficients;
# values at v in year belong to new capacity commissioned in v.
# PT and LD already contain their property/land taxes. No extra tax add-on.
param PT {city,vintage,chemistry} >= 0;
param LD {city,vintage,chemistry} >= 0;
param MT {city,vintage,chemistry} >= 0;
param IS {city,vintage,chemistry} >= 0;
param LB {city,year,chemistry} >= 0;
param GA {city,year,chemistry} >= 0;
param RM {city,year,chemistry} >= 0;
param UT {city,year,chemistry} >= 0;
param WD {city,year,chemistry} >= 0;
param RD {city,year,chemistry} >= 0;
# UT_fixed = Elec_basic, driven by retained capacity rather than throughput.
# Provide it explicitly, not defaulted to zero.
# Agreed simplification: all WD and WT, including domestic refuse, follow
# actual throughput. Their existing labor-linked learning remains upstream.
param UT_fixed {j in city,t in year,k in chemistry} >= 0 <= UT[j,t,k];
param PC {city,year,chemistry} >= 0;
param UM {city,year,chemistry} >= 0;
param WT {city,year,chemistry} >= 0;
# Compact logistics outputs: no repeated city x city x year x chemistry data.
param LC {city,candidate,year} >= 0; # logistics_result.cost, excluding value charges.
param LE {city,candidate,year} >= 0; # logistics_result.emission.
param price_rate {city,candidate} >= 0;
param BT {chemistry} >= 0; # logistics_result.battery.price, USD/t pack.

# Route coefficients are exact constant aggregation of the original six terms.
param route_cost {city,candidate,year} >= 0;
param route_emission {city,candidate,year} >= 0;

# Capacity and throughput are explicit balance variables, not substitutions.
var activation {candidate,year} binary;
var expansion {candidate,year,chemistry} >= 0;
var route {city,candidate,year} >= 0 <= 1;

var capacity {candidate,year,chemistry} >= 0;
var throughput {candidate,year,chemistry} >= 0;
subject to Stock {j in candidate,t in year,k in chemistry}:
    capacity[j,t,k] = capacity0[j,t,k]
        +sum {v in operating_vintage[t]} expansion[j,v,k];
# flow[i,j,t,k] = outflow[i,t,k] * route[i,j,t], never stored as a 4-D array.
subject to Flow {j in candidate,t in year,k in chemistry}:
    throughput[j,t,k] = sum {i in city} outflow[i,t,k]*route[i,j,t];

subject to Location {j in candidate,t in year}:
    activation[j,t] <= actor[j];
subject to Allocation {i in city,t in year}:
    sum {j in candidate} route[i,j,t] =
        (if sum {k in chemistry} outflow[i,t,k]>0 then 1 else 0);
subject to ActiveRoute {i in city,j in candidate,t in year}:
    route[i,j,t] <= activation[j,t];
subject to ProcessingLimit {j in candidate,t in year,k in chemistry}:
    throughput[j,t,k] <= capacity[j,t,k];
subject to SiteLower {j in candidate,t in year}:
    sum {k in chemistry} capacity[j,t,k] >= minimum_capacity*activation[j,t];
# Native implication: no arbitrary design-capacity upper bound or big-M.
subject to SiteInactive {j in candidate,t in year}:
    activation[j,t] = 0 ==> sum {k in chemistry} capacity[j,t,k] = 0;
subject to MaximumShare {j in candidate,t in year}:
    sum {k in chemistry} throughput[j,t,k] <=
        throughput_share_max*sum {i in city,k in chemistry} outflow[i,t,k];

# Existing asset cost0 and new annual charges use their own design-year prices.
# No upfront CI, terminal value or post-window annuity is added.
# Natural expiry only in this standard formulation; early retirement is not
# implicitly imported from preview. Existing life equals factory life.
param cost0 {j in city,t in year,k in chemistry} :=
    (PT[j,base_year,k]+LD[j,base_year,k]+MT[j,base_year,k]+IS[j,base_year,k])*capacity0[j,t,k];
var cost {j in candidate,t in year,k in chemistry} =
    cost0[j,t,k]
    +sum {v in operating_vintage[t]}
        (PT[j,v,k]+LD[j,v,k]+MT[j,v,k]+IS[j,v,k])*expansion[j,v,k]
    +(LB[j,t,k]+GA[j,t,k]+UT_fixed[j,t,k])*capacity[j,t,k]
    +(RM[j,t,k]+UT[j,t,k]-UT_fixed[j,t,k]+WD[j,t,k]+RD[j,t,k])
        *throughput[j,t,k]
    +sum {i in city} (LC[i,j,t]+price_rate[i,j]*BT[k])*outflow[i,t,k]*route[i,j,t];
var emission {j in candidate,t in year,k in chemistry} =
    (PC[j,t,k]+UM[j,t,k]+WT[j,t,k])*throughput[j,t,k]
    +sum {i in city} LE[i,j,t]*outflow[i,t,k]*route[i,j,t];

# The original cost/emission expressions above are used only for reporting.
# Objectives use aggregated route coefficients, avoiding repeated substitution.
minimize min_cost:
    sum {j in candidate,t in year,k in chemistry} DF[t]*(
        cost0[j,t,k]
        +sum {v in operating_vintage[t]}
            (PT[j,v,k]+LD[j,v,k]+MT[j,v,k]+IS[j,v,k])*expansion[j,v,k]
        +(LB[j,t,k]+GA[j,t,k]+UT_fixed[j,t,k])*capacity[j,t,k])
    +sum {i in city,j in candidate,t in year} DF[t]*route_cost[i,j,t]*route[i,j,t];
minimize min_emission:
    sum {i in city,j in candidate,t in year} route_emission[i,j,t]*route[i,j,t];
# Absolute horizon budget; endpoint interpolation is unchanged in the runner.
subject to EmissionCap {on in 1..use_epsilon}:
    sum {i in city,j in candidate,t in year} route_emission[i,j,t]*route[i,j,t] <= emission_limit;
