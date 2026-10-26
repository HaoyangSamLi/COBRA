function result = logistics(year_start, year_end, options)
%LOGISTICS Read transport/storage inputs and calculate logistics results.
%   cost/emission: origin x destination x year, USD/t and t CO2e/t.
%   battery.price: USD/t; price_rate stays dimensionless.
%   Input factors and internal helpers retain source CNY/kg units.
%   Original price_rate, battery, coordinates and scenario are retained.
%   transport_multiplier scales road transport only; default 1.
%   electric_path = [year_start year_end share_start share_end], or []
%   to use inputs/logistics.trend. Fleet shares are fractions, not tonnes.
%   Path is linear, including extrapolation; invalid shares are rejected.
%   electric_share_2040 replaces only the final fleet-share anchor (year 2040).
%   metal_price_case selects battery.price for value-related charges; cost and
%   price_rate remain separate to avoid repeated chemistry-specific arrays.
%   Reads inputs/cost_factor, emission_factor and logistics (including routes). No files saved.
arguments
    year_start (1,1) double {mustBeFinite,mustBeInteger}
    year_end (1,1) double {mustBeFinite,mustBeInteger}
    options.transport_multiplier (1,:) double {mustBeFinite,mustBeNonnegative} = []
    options.electric_share_2040 (1,:) double {mustBeFinite,mustBeReal} = []
    options.electric_path (1,:) double {mustBeFinite,mustBeReal} = []
    options.scenario (1,1) string = ""
    options.metal_price_case (1,1) string {mustBeMember(options.metal_price_case,["","low","base","high"])} = ""
end
if year_end<year_start,error('logistics:Year','year_end must be >= year_start.');end
version=fileparts(fileparts(mfilename('fullpath')));
d=load(fullfile(version,'inputs','cost_factor.mat'),'cost_factor');
g=load(fullfile(version,'inputs','emission_factor.mat'),'emission_factor');
l=load(fullfile(version,'inputs','logistics.mat'),'logistics');
if isempty(options.transport_multiplier)
    options.transport_multiplier=l.logistics.scenario.transport_multiplier;
end
if options.scenario=="",options.scenario=l.logistics.scenario.grid;end
if ~isempty(options.electric_share_2040)
    validateattributes(options.electric_share_2040,{'double'},{'scalar','>=',0,'<=',1});
    if ~isempty(options.electric_path)
        error('logistics:ElectricConflict','Specify electric_share_2040 or electric_path, not both.');
    end
    options.electric_path=l.logistics.trend{'electric_share',{'year_start','year_end','value_start','value_end'}};
    options.electric_path([2 4])=[2040 options.electric_share_2040];
end
if ~isempty(options.electric_path)
    path=options.electric_path;
    if numel(path)~=4 || any(path(1:2)~=fix(path(1:2))) || ...
            path(1)~=l.logistics.scenario.year_start || path(2)<=path(1) || any(path(3:4)<0 | path(3:4)>1)
        error('logistics:ElectricPath','Use [2025 end_year start_share end_share], shares in [0,1].');
    end
    l.logistics.trend{'electric_share',{'year_start','year_end','value_start','value_end'}}=path;
end
result=logistics_data(l.logistics,d.cost_factor,g.emission_factor,l.logistics,year_start:year_end, ...
    scenario=options.scenario,transport_multiplier=options.transport_multiplier,metal_price_case=options.metal_price_case);
% Convert once at the process output; price_rate is dimensionless.
rate=d.cost_factor.currency{'exchange_rate','value'};
validateattributes(rate,{'double'},{'scalar','real','finite','positive'});
result.cost=result.cost/rate;
result.emission=result.emission/1000;
result.battery.price=result.battery.price/rate;
end


function result = logistics_data(emap, price_data, emission_factor, param, year, options)
%LOGISTICS Calculate logistics costs, emissions and battery-price rates.
%   param is the logistics structure in inputs/logistics.mat.
%   Load with p=load(...), then pass p.logistics to avoid shadowing this function.
%   price_data contains shared modular price tables and battery prices. Output follows EMAP city order.
%   cost/emission: origin x destination x year, CNY/t and kg CO2e/t.
%   price_rate: origin x destination, including cargo insurance, inventory
%   insurance and purchase-fund occupancy. Battery prices are CNY/t pack.
%   For chemistry k: total_cost = result.cost + result.price_rate *
%   result.battery{k,'price'}. Battery purchase principal is separate.
%   Baseline vehicles provide 140000 effective loaded km/year across battery
%   jobs; each batch bears its delivery leg with no dedicated empty return.
%   Transport labor is uniform; fuel/power prices use endpoint arithmetic means.
%   Storage labor and utilities use the origin warehouse's city prices.
%   No files are read or written and no chemistry copies of cost are stored.

arguments
    emap (1,1) struct
    price_data (1,1) struct
    emission_factor (1,1) struct
    param (1,1) struct
    year (1,:) double {mustBeFinite,mustBeInteger}
    options.transport_multiplier (1,1) double {mustBeFinite,mustBeNonnegative} = 1
    options.scenario (1,1) string = ""
    options.metal_price_case (1,1) string {mustBeMember(options.metal_price_case,["","low","base","high"])} = ""
end

cef=emission_factor.grid;
diesel_factor=emission_factor.utility{'diesel','value'};
chemistry = {'LFP';'LMO';'NCM-L';'NCM-M';'NCM-H';'NCA'};
battery = price_data.battery;
if ~istable(battery) || height(battery)~=6 ...
        || ~isequal(battery.Properties.VariableNames,{'low','base','high'})
    error('logistics:InvalidBattery','battery must contain low/base/high and chemistry row names.');
end
[found,index]=ismember(string(chemistry),string(battery.Properties.RowNames));
if ~all(found) || numel(unique(string(battery.Properties.RowNames)))~=6
    error('logistics:InvalidBattery','Battery chemistry names must be unique and complete.');
end
% Keep the one-column output; select the same acquisition scenario as recovery.
price_case=options.metal_price_case;if price_case=="",price_case="base";end
battery = table(battery{index,char(price_case)},'VariableNames',{'price'},'RowNames',chemistry);
if ~isnumeric(battery.price) || ~isreal(battery.price) ...
        || any(~isfinite(battery.price) | battery.price<0)
    error('logistics:InvalidBattery','Battery prices must be finite and nonnegative.');
end

t = transport(emap,price_data,cef,param,year,diesel_factor,scenario=options.scenario,transport_multiplier=options.transport_multiplier);
s = storage(emap,price_data,cef,param,year,scenario=t.scenario);
result = struct('city_ch',t.city_ch,'city_en',t.city_en,'year',year(:), ...
    'scenario',t.scenario,'cost',t.cost+s.cost, ...
    'emission',t.emission+reshape(s.emission,numel(t.city_ch),1,numel(year)), ...
    'price_rate',t.cargo_insurance_rate+s.price_rate,'battery',battery);
end


function logistics = transport(emap, price_data, cef, param, year, diesel_factor, options)
%TRANSPORT Calculate city-pair transport cost and emissions by year.
%   logistics = transport(emap,price_data,cef,param,year,scenario="S1")
%   param is the logistics structure stored in inputs/logistics.mat.
%   price_data contains shared regional prices in labor, land and utility.
%   Select one CEF scenario explicitly if cef contains several scenarios.
%
%   Output city order follows EMAP; PRICE and CEF are matched by city_ch.
%   cost and emission are origin x destination x year arrays, in CNY/t and
%   kg CO2e/t of delivered battery respectively. cost includes packaging and
%   one factory handling charge, but excludes cargo insurance. Add
%   cargo_insurance_rate * battery purchase price (CNY/t) in the optimizer.
%
%   labor_cost is the annual personnel total per vehicle, uniformly 144000 CNY
%   at baseline for both powertrains; it is independent of city wages.
%   PRICE diesel (CNY/L) and electricity (CNY/kWh) use baseline prices.
%   Their endpoint arithmetic means represent route energy procurement prices,
%   consistent with refuelling/charging across consecutive transport jobs.
%   CEF factors also use the mean of the two route endpoints.
%   Annual purchase prices and energy use follow linear relative trends from
%   the 2025 ICCT baseline. IEA purchase-price anchors span report editions
%   and dollar years: their ratios are a research proxy, not harmonized costs.
%   Electric stock share is converted to payload-weighted transport share.
%   The agreed interpolation/extrapolation horizon is 2025:2060.
%
%   Baseline annual_distance=140000 is effective loaded service km per vehicle:
%   continuous battery jobs share vehicle use, including reverse-direction
%   jobs. This utilization assumption does not allocate dedicated empty returns.
%   Each batch bears only its delivery leg at return_factor=1. For comparison,
%   return_factor=2 charges the actual reverse leg as well. Route mileage is
%   D(i,j) + (return_factor-1)*D(j,i), retaining EMAP directional distances;
%   intracity toll is zero. Packaging and handling are charged once per tonne.
%   Annual representative vehicle costs do not model purchase-year cohorts.
%   No blanket logistics learning rate or additional charging fee is applied.
%   This function reads/writes no files.

arguments
    emap (1,1) struct
    price_data (1,1) struct
    cef (1,1) struct
    param (1,1) struct
    year (1,:) double {mustBeFinite,mustBeInteger}
    diesel_factor (1,1) double {mustBeFinite,mustBePositive}
    options.transport_multiplier (1,1) double {mustBeFinite,mustBeNonnegative} = 1
    options.scenario (1,1) string = ""
end

if isempty(year) || any(diff(year)<=0) || any(year<param.scenario.year_start | year>param.scenario.year_end)
    error('transport:InvalidYear','year must contain increasing unique years within %d:%d.',param.scenario.year_start,param.scenario.year_end);
end
city_ch = string(emap.city.Properties.RowNames);
city_en = string(emap.city.city_en(:));
city_count = numel(city_ch);
transport_city_index(city_ch,city_ch);
if numel(city_en)~=city_count || any(ismissing(city_en) | strlength(city_en)==0)
    error('transport:InvalidCities','EMAP must provide matching city_ch and city_en labels.');
end
distance = route_values(emap.distance,city_ch);
if ~isequal(size(distance),[city_count city_count]) || ~isreal(distance) ...
        || any(~isfinite(distance) | distance<0,'all')
    error('transport:InvalidDistance','EMAP distance must be a finite nonnegative city x city matrix in km.');
end
factor_index = transport_city_index(city_ch,string(cef.city.Properties.RowNames));
diesel_price = transport_regional_price(price_data.utility,city_ch,"diesel");
electricity_price = transport_regional_price(price_data.utility,city_ch,"electricity");
if any(~isfinite([diesel_price;electricity_price]) | [diesel_price;electricity_price]<0)
    error('transport:InvalidPrice','Diesel and electricity prices must be finite nonnegative.');
end
diesel_price = (diesel_price+diesel_price')/2;
electricity_price = (electricity_price+electricity_price')/2;

scenario = string(cef.scenario(:));
if numel(unique(scenario))~=numel(scenario) || any(ismissing(scenario) | strlength(scenario)==0)
    error('transport:InvalidScenario','CEF scenario labels must be unique and nonempty.');
end
if options.scenario=="" && isscalar(scenario)
    scenario_index = 1;
else
    scenario_index = find(scenario==options.scenario);
end
if ~isscalar(scenario_index)
    error('transport:InvalidScenario','Select one available CEF scenario explicitly.');
end
[found,year_index] = ismember(year,cef.year);
if ~all(found) || numel(unique(cef.year))~=numel(cef.year) ...
        || size(cef.factor,1)~=numel(string(cef.city.Properties.RowNames)) ...
        || size(cef.factor,2)~=numel(cef.year) || size(cef.factor,3)~=numel(scenario)
    error('transport:InvalidCEF','CEF dimensions must match its labels and contain every requested year.');
end
factor = cef.factor(factor_index,year_index,scenario_index);
if any(~isfinite(factor) | factor<0,'all')
    error('transport:InvalidCEF','Selected CEF values must be finite and nonnegative.');
end

% Read by parameter name; row order is only for readability of the asset.
vehicle = param.vehicle;
operation = param.transport;
package = param.package;
vehicle_rows = {'payload','purchase_tax_rate','residual_rate'};
vehicle_price=price_data.vehicle;
operation_price=price_data.transport;
package_price=price_data.package;
for t={vehicle_price,operation_price,package_price}
    values=t{1}{:,:};
    if ~isreal(values) || any(~isfinite(values) | values<0,'all')
        error('transport:InvalidPrice','Logistics prices must be finite and nonnegative.');
    end
end
vehicle_values = vehicle{vehicle_rows,{'diesel','electric'}};
operation_values = operation{:, 'value'};
package_values = package{:, 'value'};
if any(~isfinite(vehicle_values) | vehicle_values<0,'all') ...
        || any(~isfinite(operation_values) | operation_values<0) ...
        || any(~isfinite(package_values) | package_values<0)
    error('transport:InvalidParameter','Applicable transport parameters must be finite and nonnegative.');
end
life = operation{'vehicle_life','value'};
rate = operation{'discount_rate','value'};
annual_distance = operation{'annual_distance','value'};
load_factor = operation{'load_factor','value'};
return_factor = operation{'return_factor','value'};
payload = vehicle{'payload',{'diesel','electric'}}*load_factor;
if life<=0 || annual_distance<=0 || load_factor<=0 || load_factor>1 ...
        || return_factor<1 || any(payload<=0) ...
        || package{'cycles','value'}<=0 || package{'battery_mass','value'}<=0 ...
        || any(vehicle{'residual_rate',{'diesel','electric'}}>1) ...
        || operation{'cargo_insurance_rate','value'}>1
    error('transport:InvalidParameter','Check lifetime, mileage, load, return, package and residual/insurance fractions.');
end
diesel_use = vehicle{'diesel_use','diesel'};
electricity_use = vehicle{'electricity_use','electric'};
if any(~isfinite([diesel_use electricity_use diesel_factor])) ...
        || any([diesel_use electricity_use diesel_factor]<=0)
    error('transport:InvalidEnergy','Applicable energy use and diesel factor must be finite and positive.');
end

trend_rows = {'electric_share','purchase_cost_diesel','purchase_cost_electric', ...
    'diesel_use','electricity_use'};
all_trends=[param.trend;price_data.trend];
trend = all_trends{trend_rows,{'year_start','year_end','value_start','value_end'}};
if any(~isfinite(trend),'all') || any(trend(:,1)~=param.scenario.year_start) ...
        || any(trend(:,2)<=trend(:,1)) || any(trend(2:5,3:4)<=0,'all') ...
        || any(trend(1,3:4)<0 | trend(1,3:4)>1)
    error('transport:InvalidTrend','Trend anchors must start in 2025 with positive technical values and valid shares.');
end
values = trend(:,3)+(trend(:,4)-trend(:,3)).*(year-trend(:,1))./(trend(:,2)-trend(:,1));
share = values(1,:);
scale = values(2:5,:)./trend(2:5,3);
if any(share<0 | share>1) || any(scale<=0 | ~isfinite(scale),'all')
    error('transport:InvalidTrend','Extrapolation produced invalid shares or nonpositive technical values.');
end
purchase_cost = vehicle_price{'purchase_cost',{'diesel','electric'}}'.*scale(1:2,:);
diesel_use = diesel_use*scale(3,:);
electricity_use = electricity_use*scale(4,:);
% Equal annual mileage: fleet counts become delivered-tonnage weights.
electric_share = payload(2)*share./(payload(1)*(1-share)+payload(2)*share);

% Tax-inclusive purchase cost; resale value excludes the purchase-tax part.
residual = purchase_cost./(1+vehicle{'purchase_tax_rate',{'diesel','electric'}}') ...
    .*vehicle{'residual_rate',{'diesel','electric'}}';
if rate==0
    capital_cost = (purchase_cost-residual)/life;
else
    discount = (1+rate)^(-life);
    capital_cost = (purchase_cost-residual*discount)*rate/(1-discount);
end
fixed_cost = sum(vehicle_price{{'maintenance_cost','insurance_cost','ownership_tax'}, ...
    {'diesel','electric'}},1)'+operation_price{'labor_cost','base'};
fixed_cost = (capital_cost+fixed_cost)/annual_distance;
package_cost = (package_price{'purchase_cost','base'}/package{'cycles','value'} ...
    +package_price{'liner_cost','base'}+package_price{'handling_cost','base'})/package{'battery_mass','value'};
distance = distance+(return_factor-1)*distance';
toll = operation_price{'toll_rate','base'}*ones(city_count);
toll(1:city_count+1:end) = 0;

cost = zeros(city_count,city_count,numel(year));
emission = zeros(size(cost));
for k = 1:numel(year)
    cost_diesel = (fixed_cost(1,k)+diesel_use(k)*diesel_price+toll)/payload(1);
    cost_electric = (fixed_cost(2,k)+electricity_use(k)*electricity_price+toll)/payload(2);
    factor_mean = (factor(:,k)+factor(:,k)')/2;
    emission_diesel = diesel_use(k)*diesel_factor/payload(1);
    emission_electric = electricity_use(k)*factor_mean/payload(2);
    cost(:,:,k) = options.transport_multiplier*(distance.*((1-electric_share(k))*cost_diesel ...
        +electric_share(k)*cost_electric))+package_cost;
    emission(:,:,k) = distance.*((1-electric_share(k))*emission_diesel ...
        +electric_share(k)*emission_electric);
end
logistics = struct('city_ch',city_ch,'city_en',city_en,'year',year(:), ...
    'scenario',scenario(scenario_index),'cost',cost,'emission',emission, ...
    'cargo_insurance_rate',operation{'cargo_insurance_rate','value'});
end


function index = transport_city_index(target,source)
% Chinese city names are the key; English names may be duplicated.
source = string(source(:));
[found,index] = ismember(target,source);
if isempty(source) || numel(unique(source))~=numel(source) ...
        || any(ismissing(source) | strlength(strip(source))==0) || ~all(found)
    error('transport:CityMismatch','City labels must be unique, nonempty and cover all EMAP cities.');
end
end

function value=transport_regional_price(t,city_ch,name)
if name=="wage",name="base";end
index=transport_city_index(city_ch,string(t.Properties.RowNames));
value=t.(name)(index);
end


function result = storage(emap, price_data, cef, param, year, options)
%STORAGE Calculate origin-city storage cost and route-dependent price rates.
%   price_data holds the shared modular prices; param holds logistics parameters.
%   cost is city x 1 in CNY/t; emission is city x year in kg CO2e/t.
%   price_rate is origin x destination: multiply by battery price in CNY/t
%   for inventory insurance and purchase-fund occupancy. Purchase principal
%   and transport cargo insurance are not included in this coefficient.
%   Reference annual costs scale with throughput, not with waiting months.
%   Wages and utility prices use the origin warehouse's city values.

arguments
    emap (1,1) struct
    price_data (1,1) struct
    cef (1,1) struct
    param (1,1) struct
    year (1,:) double {mustBeFinite,mustBeInteger}
    options.scenario (1,1) string = ""
end

if isempty(year) || any(diff(year)<=0) || any(year<param.scenario.year_start | year>param.scenario.year_end)
    error('storage:InvalidYear','year must increase within %d:%d.',param.scenario.year_start,param.scenario.year_end);
end
city_ch = string(emap.city.Properties.RowNames);
city_en = string(emap.city.city_en(:));
n = numel(city_ch);
storage_city_index(city_ch,city_ch);
if numel(city_en)~=n || any(ismissing(city_en) | strlength(city_en)==0)
    error('storage:InvalidCities','EMAP city labels must have matching lengths.');
end
prices = [storage_regional_price(price_data.land,city_ch,"storage"), ...
    storage_regional_price(price_data.labor,city_ch,"wage"), ...
    storage_regional_price(price_data.utility,city_ch,"electricity"), ...
    storage_regional_price(price_data.utility,city_ch,"fresh_water"), ...
    storage_regional_price(price_data.utility,city_ch,"wastewater")];
if ~isreal(prices) || any(~isfinite(prices) | prices<0,'all')
    error('storage:InvalidPrice','Storage factor prices must be finite and nonnegative.');
end
provinces = route_values(emap.number_of_provinces,city_ch);
if ~isequal(size(provinces),[n n]) || ~isreal(provinces) ...
        || any(~isfinite(provinces) | provinces<1 | provinces~=fix(provinces),'all')
    error('storage:InvalidRoute','Province counts must be positive integers in a city x city matrix.');
end

scenario = string(cef.scenario(:));
if numel(unique(scenario))~=numel(scenario) || any(ismissing(scenario) | strlength(scenario)==0)
    error('storage:InvalidScenario','CEF scenario labels must be unique and nonempty.');
end
if options.scenario=="" && isscalar(scenario)
    selected = 1;
else
    selected = find(scenario==options.scenario);
end
if ~isscalar(selected)
    error('storage:InvalidScenario','Select one available CEF scenario explicitly.');
end
[found,time_index] = ismember(year,cef.year);
if ~all(found) || numel(unique(cef.year))~=numel(cef.year) ...
        || size(cef.factor,1)~=numel(string(cef.city.Properties.RowNames)) ...
        || size(cef.factor,2)~=numel(cef.year) || size(cef.factor,3)~=numel(scenario)
    error('storage:InvalidCEF','CEF dimensions and requested years must match its labels.');
end
index = storage_city_index(city_ch,string(cef.city.Properties.RowNames));
factor = cef.factor(index,time_index,selected);
if ~isreal(factor) || any(~isfinite(factor) | factor<0,'all')
    error('storage:InvalidCEF','Selected CEF values must be finite and nonnegative.');
end

p = param.storage;
value = @(name) p{name,'value'};
price_value = @(name) price_data.storage{name,'base'};
if any(~isfinite(price_data.storage.base) | price_data.storage.base<0)
    error('storage:InvalidPrice','Storage prices must be finite and nonnegative.');
end
if ~isreal(p.value) || any(~isfinite(p.value) | p.value<0)
    error('storage:InvalidParameter','Storage parameters must be finite and nonnegative.');
end
area = value('building_area');
land_area = value('land_area');
mass = value('annual_mass');
rate = value('discount_rate');
life = value('building_life');
equipment_life = value('equipment_life');
fractions = p{{'building_residual_rate','equipment_residual_rate', ...
    'land_residual_rate','setup_residual_rate','property_insurance_rate','property_tax_rate'},'value'};
if any([area land_area mass life equipment_life]<=0) || any(fractions>1)
    error('storage:InvalidParameter','Check areas, throughput, lifetimes and fractional rates.');
end

land = land_area*prices(:,1);
building = area*price_value('building_cost');
equipment = area*price_value('equipment_cost');
capital = annual_cost(land,rate,life,value('land_residual_rate')) ...
    +annual_cost(building,rate,life,value('building_residual_rate')) ...
    +annual_cost(equipment,rate,equipment_life,value('equipment_residual_rate')) ...
    +annual_cost(price_value('setup_cost'),rate,life,value('setup_residual_rate'));

% PRICE water and treatment are separate charges, both in CNY/m3.
running = value('staff')*prices(:,2) ...
    +value('electricity_use')*prices(:,3) ...
    +value('water_use')*(prices(:,4)+prices(:,5)) ...
    +price_value('maintenance_cost')+price_value('management_cost');
insurance = (building+equipment)*value('property_insurance_rate');
tax = (land+building+equipment)*value('property_tax_rate') ...
    +land_area*price_value('land_tax');
cost = (capital+running+insurance+tax)/mass;
emission = value('electricity_use')/mass*factor;

months = value('base_months')+value('province_months')*(provinces-1);
price_rate = months/12*(rate+value('property_insurance_rate'));
result = struct('city_ch',city_ch,'city_en',city_en,'year',year(:), ...
    'scenario',scenario(selected),'cost',cost,'emission',emission, ...
    'price_rate',price_rate);
end


function cost = annual_cost(investment,rate,life,residual_rate)
if rate==0
    cost = investment*(1-residual_rate)/life;
else
    discount = (1+rate)^(-life);
    cost = investment*(1-residual_rate*discount)*rate/(1-discount);
end
end


function index = storage_city_index(target,source)
source = string(source(:));
[found,index] = ismember(target,source);
if isempty(source) || numel(unique(source))~=numel(source) ...
        || any(ismissing(source) | strlength(strip(source))==0) || ~all(found)
    error('storage:CityMismatch','City labels must be unique and cover all EMAP cities.');
end
end

function value=storage_regional_price(t,city_ch,name)
if name=="wage",name="base";end
index=storage_city_index(city_ch,string(t.Properties.RowNames));
value=t.(name)(index);
end

function value=route_values(t,city)
% Named origin/destination coordinates must agree with the city table.
if ~istable(t) || ~isequal(string(t.Properties.RowNames),city) || ...
        ~isequal(string(t.Properties.VariableNames(:)),city)
    error('logistics:Route','Route table coordinates differ from city labels.');
end
value=t{:,:};
end
