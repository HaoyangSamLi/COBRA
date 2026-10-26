function [result, auxiliary] = recovery(year_start, year_end, options)
%RECOVERY Read factory inputs and calculate costs and emissions.
%   Costs: USD/t pack; PC/UM/WT/RE: t CO2e/t pack.
%   Metadata: city, year, chemistry, window, scenario. Window is (start,end].
%   Optional auxiliary.UT_fixed is passed internally to optimization, not saved.
%   Internal helpers use source CNY/kg units; the public result converts once.
%   experience: year x 2 cumulative Q/Q0 for LFP and non-LFP.
%   Scalar/shared annual row inputs remain supported; default 1 is baseline.
%   learning_rate overrides recovery.learning in memory only. No files saved.
%   metal_price_case selects Li/Ni/Co/Mn chemical commodities only here;
%   logistics uses the same selector for battery-related value charges.
%   Equipment, utilities, scrap metals and other commodity prices stay fixed.
arguments
    year_start (1,1) double {mustBeFinite,mustBeInteger}
    year_end (1,1) double {mustBeFinite,mustBeInteger}
    options.experience double = []
    options.learning_rate (1,:) double = []
    options.utilization (1,:) double = []
    options.price_case (1,1) string {mustBeMember(options.price_case,["","low","base","high"])} = ""
    options.metal_price_case (1,1) string {mustBeMember(options.metal_price_case,["","low","base","high"])} = ""
    options.equipment_case (1,1) string {mustBeMember(options.equipment_case,["","low","base","high"])} = ""
    options.scenario (1,1) string = ""
end
if year_end<year_start || year_end>2060,error('recovery:Year','Use year_start <= year_end <= 2060.');end
version=fileparts(fileparts(mfilename('fullpath')));
r=load(fullfile(version,'inputs','recovery.mat'),'recovery');
d=load(fullfile(version,'inputs','cost_factor.mat'),'cost_factor');
g=load(fullfile(version,'inputs','emission_factor.mat'),'emission_factor');
p.parameter=r.recovery.parameter;
l.learning=r.recovery.learning;
for key=["experience","utilization","price_case","equipment_case"]
    value=options.(key);
    if isempty(value) || (isstring(value) && value=="")
        options.(key)=r.recovery.scenario.(key);
    end
end
if options.scenario=="",options.scenario=r.recovery.scenario.grid;end
if ~isempty(options.learning_rate)
    validateattributes(options.learning_rate,{'double'},{'scalar','real','finite','>=',0,'<',1});
    l.learning.factor{'learning_rate','value'}=options.learning_rate;
end
options=rmfield(options,'learning_rate');
options.emission_factor=g.emission_factor;
options.material_electricity=r.recovery.material_electricity;
physical=rmfield(r.recovery,{'parameter','learning','scenario','material_electricity'});
args=namedargs2cell(options);
rate=d.cost_factor.currency{'exchange_rate','value'};
if nargout>1
    [result,auxiliary]=recovery_data(physical,d.cost_factor,p.parameter,year_start,year_end,l.learning,args{:});
    auxiliary.UT_fixed=auxiliary.UT_fixed/rate;
else
    result=recovery_data(physical,d.cost_factor,p.parameter,year_start,year_end,l.learning,args{:});
end
clear r d g p l physical args options
% Convert monetary and emission outputs once; input factors retain source units.
validateattributes(rate,{'double'},{'scalar','real','finite','positive'});
costs=["RC","PT","LD","RM","UT","WD","LB","MT","IS","RD","GA"];
for name=costs
    result.(name)=result.(name)/rate;
end
for name=["PC","UM","WT","RE"]
    result.(name)=result.(name)/1000;
end
end


function [result, auxiliary] = recovery_data(data, price_data, parameter, year_start, year_end, learning, options)
%RECOVERY Factory costs and emissions, city x year x chemistry.
%   Calls recovery_intensity, acc/fcop/vcop and pc/um/wt.
%   Pass emission_factor to also return PC/UM/WT/RE in kg CO2e/t pack.
%   Select a grid scenario explicitly when multiple exist.
%   Omitting all emission inputs retains the previous cost-only interface.
%   Emission factors material/utility/waste/grid are all in inputs/emission_factor.mat.
%   data is inputs/recovery.mat's recovery; parameter is recovery.parameter's parameter.
%   All prices are read from PRICE groups, using their ranges or fixed base;
%   chemistry, active-content and moisture conversions are already applied.
%   Load into structures (p=load(...), then p.recovery) to avoid name shadowing.
%   Internal prices and costs are CNY, converted at the public output edge.
%   Gross RC excludes battery purchase, logistics, VAT, CIT and carbon fees.
%   Factory working-capital costs are excluded; logistics funding is separate.
%   PT includes property tax; LD includes land-use tax.
%   Monetary arrays are per actual t pack, city x year x chemistry.
%   Shared learning applies to the remaining base-floor gap, not prices.
%   experience has two pools (year x 2), or a shared scalar/annual row.
%   Omitted means no learning. Existing assets are not retrospectively depreciated.
%   No I/O, optimization or city x year x chemistry x item tensor is created.
arguments
    data (1,1) struct
    price_data (1,1) struct
    parameter (1,1) struct
    year_start (1,1) double {mustBeFinite,mustBeInteger}
    year_end (1,1) double {mustBeFinite,mustBeInteger}
    learning (1,1) struct
    options.experience double = 1
    options.utilization (1,1) double = 1
    options.price_case (1,1) string {mustBeMember(options.price_case,["low","base","high"])} = "base"
    options.metal_price_case (1,1) string {mustBeMember(options.metal_price_case,["","low","base","high"])} = ""
    options.equipment_case (1,1) string {mustBeMember(options.equipment_case,["","low","base","high"])} = ""
    options.emission_factor (1,1) struct = struct
    options.material_electricity table = table
    options.scenario (1,1) string = ""
end
if year_end<year_start
    error('recovery:Year','year_end must be >= year_start.');
end
year=year_start:year_end;
p=parameter.factor;check_nonnegative(p.value,'factor');v=@(name) p{name,'value'};
validateattributes(price_data.currency{'exchange_rate','value'},{'double'},{'scalar','real','finite','positive'});
if v('economic_life')<=0 || price_data.currency{'exchange_rate','value'}<=0 || learning.factor{'learning_rate','value'}>=1 ...
        || any(p{{'land_residual_rate','capital_residual_rate','property_equipment_share','power_factor','transformer_loading'},'value'}>1) ...
        || v('power_factor')<=0 || v('transformer_loading')<=0
    error('recovery:Parameter','Invalid lifetime, exchange rate or fractional assumption.');
end
util=options.utilization;
if ~isfinite(util) || util<=0 || util>1,error('recovery:Utilization','utilization must be in (0,1].');end
[design,names,chemistry,gap]=recovery_intensity(data,learning.factor{'learning_rate','value'},options.experience,numel(year),learning.group);
t=price_data.city; n=height(t);
city_ch=string(t.Properties.RowNames);city_en=string(t.city_en(:));
if n==0 || numel(unique(city_ch))~=n || any(ismissing(city_ch) | strlength(strip(city_ch))==0)
    error('recovery:City','PRICE cities must be unique and nonempty.');
end
c=find(["low","base","high"]==options.price_case);
wage=regional_price(price_data.labor,city_ch,"wage");
land_price=regional_price(price_data.land,city_ch,"industry");
land_tax=regional_price(price_data.land,city_ch,"land_tax");
check_nonnegative([wage land_price land_tax],'city prices');
u=struct;
for key=["electricity","power_demand","capacity_charge","natural_gas","steam","fresh_water","wastewater"]
    u.(key)=regional_price(price_data.utility,city_ch,key);
    if ~any(key==["power_demand","capacity_charge"]),check_nonnegative(u.(key),'utility prices');end
end
% The seven Tibet cities have capacity tariffs, not a published demand rate.
% Never replace missing demand prices by zero or charge BOTH tariff systems.
demand=u.power_demand;capacity=u.capacity_charge;
if any(isinf(demand) | demand<0),error('recovery:Tariff','Invalid demand tariff.');end
fallback=isnan(demand);check_nonnegative(capacity(fallback),'capacity fallback');
basic_rate=demand;
basic_rate(fallback)=capacity(fallback)/(v('power_factor')*v('transformer_loading'));
check_nonnegative(basic_rate,'basic tariff');

eq=parameter.equipment;
if ~isequal(string(eq.Properties.RowNames),names.equipment) || ~all(ismember(eq.scope,["ISBL","OSBL"]))
    error('recovery:Equipment','Equipment keys or ISBL/OSBL assignments differ.');
end
ec=c;if options.equipment_case~="",ec=find(["low","base","high"]==options.equipment_case);end
install=eq{:,{'install_low','install_base','install_high'}};
check_nonnegative(install,'installation factor');
installed_unit=prices(price_data.equipment,string(eq.Properties.RowNames),ec).*install(:,ec);
inprice=prices(price_data.material,names.material,c);
outprice=prices(price_data.product,names.product,c);
% Select Li/Ni/Co/Mn chemical commodities, independently of general price_case.
% Scrap steel stays at the general price case even though it contains nickel.
if options.metal_price_case~=""
    mc=find(["low","base","high"]==options.metal_price_case);
    material_rows=ismember(names.material,"manganese_sulfate_32mn");
    product_rows=ismember(names.product,["ncm811_precursor","lithium_carbonate_99_5", ...
        "cobalt_sulfate_20_5co","manganese_sulfate_32mn"]);
    if nnz(material_rows)~=1 || nnz(product_rows)~=4
        error('recovery:MetalPrices','Expected metal commodity price rows are missing.');
    end
    selected=prices(price_data.material,names.material,mc);inprice(material_rows)=selected(material_rows);
    selected=prices(price_data.product,names.product,mc);outprice(product_rows)=selected(product_rows);
end
wasteprice=prices(price_data.waste,names.waste,c);
building_price=prices(price_data.building,names.building,c);
if ~isequal(string(parameter.labor.Properties.RowNames),names.labor)
    error('recovery:Allocation','Labor allocation rows differ.');
end
building_share=cell(1,2);state_names={'base','floor'};
for state=1:2
    t=parameter.building.(state_names{state});
    if ~isequal(string(t.Properties.RowNames),names.building) || ...
            ~isequal(string(t.Properties.VariableNames(:)),chemistry)
        error('recovery:Allocation','Building allocation coordinates differ.');
    end
    building_share{state}=t{:,:};check_nonnegative(building_share{state},'building allocation');
    if any(building_share{state}>1,'all'),error('recovery:Allocation','Building shares exceed one.');end
end

% Cost each compatible endpoint, then interpolate city x 6 arrays.
% Keep base/floor building allocations paired with their own designs.
price=struct('equipment',installed_unit,'building',building_price, ...
    'land',land_price,'land_tax',land_tax,'wage',wage,'material',inprice, ...
    'waste',wasteprice,'utility',u,'basic_rate',basic_rate);
endpoints=cell(1,2);
for s=1:2
    x=design{s};
    RV=repmat(outprice.'*x.product,n,1);
    [a,capital]=acc(x,price,parameter,building_share{s},util);
    f=fcop(x,price,parameter,capital,RV,util);
    w=vcop(x,price,names,util);
    % Preserve historical field order and arithmetic grouping exactly.
    z=struct;
    z.PT=a.PT;z.LD=a.LD;z.RM=w.RM;z.UT=w.UT;z.WD=w.WD;
    z.LB=f.LB;z.GA=f.GA;z.RD=f.RD;z.MT=f.MT;z.IS=f.IS;
    z.RC=z.PT+z.LD+z.RM+z.UT+z.WD+z.LB+z.MT+z.IS+(z.RD+z.GA);
    z.UT_fixed=w.UT_fixed;
    endpoints{s}=z;
end
metal_case=options.metal_price_case;if metal_case=="",metal_case=options.price_case;end
result=struct('city',table(city_en,'VariableNames',{'city_en'},'RowNames',cellstr(city_ch)), ...
    'year',year(:),'chemistry',chemistry(:),'window',[year_start-1;year_end], ...
    'scenario',struct('learning_rate',learning.factor{'learning_rate','value'}, ...
        'metal_price_case',metal_case,'grid_case',options.scenario));
output_names=["RC","PT","LD","RM","UT","WD","LB","MT","IS","RD","GA"];
for k=1:numel(output_names)
    name=output_names{k};a=reshape(endpoints{1}.(name),n,1,6);b=reshape(endpoints{2}.(name),n,1,6);
    result.(name)=b+(a-b).*gap;
end
if nargout>1
    a=reshape(endpoints{1}.UT_fixed,n,1,6);b=reshape(endpoints{2}.UT_fixed,n,1,6);
    auxiliary=struct('UT_fixed',b+(a-b).*gap);
end
clear endpoints price RV capital a b f w z

if ~isempty(fieldnames(options.emission_factor)) || options.scenario~=""
    if ~all(isfield(options.emission_factor,{'material','utility','waste','grid'}))
        error('recovery:EmissionInputs','Emission factors must provide material, utility, waste and grid.');
    end
    [ghg,ef,grid,scenario]=emission_inputs(options,names,city_ch,year);
    PC=pc(design,names,gap,ef.utility,grid);
    UM=um(design,names,gap,ghg,ef.utility,grid);
    WT=wt(design,names,gap,ef.waste,ef.utility,n,util);
    result.RE=PC+UM+WT;result.PC=PC;result.UM=UM;result.WT=WT;
    result.scenario.grid_case=scenario;
end
end

function value=prices(t,names,c)
[found,j]=ismember(names,string(t.Properties.RowNames));
if numel(unique(t.Properties.RowNames))~=height(t) || numel(names)~=height(t) || ~all(found),error('recovery:Prices','Missing/duplicate commodity prices.');end
columns={'low','base','high'};
if isequal(t.Properties.VariableNames,{'base'}),c=2;end
value=t.(columns{c})(j);check_nonnegative(value,'commodity prices');
end
function value=regional_price(t,target,name)
if name=="wage",name="base";end
source=string(t.Properties.RowNames);[found,j]=ismember(target,source);
if numel(unique(source))~=numel(source) || ~all(found)
    error('recovery:CityPrices','Missing/duplicate city price keys.');
end
value=t.(name)(j);
end
function check_nonnegative(x,label)
if ~isnumeric(x) || ~isreal(x) || any(~isfinite(x) | x<0,'all')
    error('recovery:Value','%s must be finite and nonnegative.',label);
end
end

function [ghg,ef,grid,selected]=emission_inputs(options,names,city_ch,year)
% Validate coverage and join by names, never by incidental source row order.
% Material.value is the fixed part a; material_electricity is b in a+b*grid.
% External fixed proxies already contain their source electricity background.
% Waste.value is per kg dispatched material (wet mass where applicable).
% It excludes the separately tracked spent-extractant/residual battery carbon.
% Calibration provenance is in analysis/20261025_emission_factor_audit.
if ~isequal(sort(names.utility),sort(["electricity";"power_demand";"natural_gas";"steam";"fresh_water";"wastewater"])) ...
        || ~isequal(sort(names.direct_emission),sort(["process_co2";"spent_organic_co2";"residual_organic_co2"]))
    error('recovery:EmissionCoverage','Utility/direct-carbon mapping needs explicit review.');
end
ghg=align_factor(options.emission_factor.material,names.material,{'value'});
ghg.Properties.VariableNames={'fixed'};
upstream=align_factor(options.material_electricity,names.material,{'value'});
ghg.electricity=upstream.value;
ef=struct('utility',options.emission_factor.utility,'waste',options.emission_factor.waste);
if ~isequal(sort(string(fieldnames(ef))),["utility";"waste"])
    error('recovery:EmissionFactor','Expected utility and waste emission tables.');
end
factory_utility=["natural_gas";"steam";"fresh_water";"wastewater"];
ef.utility=align_factor(ef.utility(factory_utility,:),factory_utility,{'value'});
ef.waste=align_factor(ef.waste,names.waste,{'value'});
c=options.emission_factor.grid;
if ~all(isfield(c,{'city','year','scenario','factor'})) || ~istable(c.city)
    error('recovery:CEF','CEF must provide named city, year, scenario and factor.');
end
city=string(c.city.Properties.RowNames);scenarios=string(c.scenario(:));
if isempty(city) || numel(unique(city))~=numel(city) || any(ismissing(city) | strlength(strip(city))==0) ...
        || isempty(scenarios) || numel(unique(scenarios))~=numel(scenarios) ...
        || any(ismissing(scenarios) | strlength(strip(scenarios))==0)
    error('recovery:CEF','CEF city and scenario labels must be unique and nonempty.');
end
selected=options.scenario;
if selected=="" && isscalar(scenarios),selected=scenarios(1);end
k=find(scenarios==selected);
if ~isscalar(k),error('recovery:CEFScenario','Select one available CEF scenario explicitly.');end
[found,ix]=ismember(city_ch,city);[found_year,iy]=ismember(year,c.year);
if ~all(found) || ~all(found_year) || numel(unique(c.year))~=numel(c.year) ...
        || ~isnumeric(c.factor) || ndims(c.factor)>3 ...
        || size(c.factor,1)~=numel(city) || size(c.factor,2)~=numel(c.year) || size(c.factor,3)~=numel(scenarios)
    error('recovery:CEF','CEF coordinates/dimensions must cover all requested cities and years.');
end
grid=c.factor(ix,iy,k);check_nonnegative(grid,'grid factors');
end

function t=align_factor(t,names,columns)
if ~istable(t) || ~isequal(t.Properties.VariableNames,columns) ...
        || height(t)~=numel(names) || numel(t.Properties.RowNames)~=height(t)
    error('recovery:EmissionFactor','Emission factor table coordinates differ.');
end
[found,j]=ismember(names,string(t.Properties.RowNames));
if ~all(found) || numel(unique(t.Properties.RowNames))~=height(t)
    error('recovery:EmissionFactor','Missing/duplicate emission factor keys.');
end
t=t(j,:);check_nonnegative(t{:,:},'emission factors');
end


function [cost, capital] = acc(x, price, parameter, building_share, utilization)
%ACC Investment and annual capital charges for one compatible plant design.
%   Internal recovery helper: x contains item x chemistry physical arrays.
%   Cost arrays are city x chemistry, including property and land-use taxes.
%   capital contains shared investment bases, not additional annual costs.
v=@(name) parameter.factor{name,'value'};
eq=parameter.equipment;q=x.equipment;
isbl_eq=(price.equipment.*(eq.scope=="ISBL")).'*q;
osbl_eq=(price.equipment.*(eq.scope=="OSBL")).'*q;
embedded=(price.equipment.*double(eq.embedded)).'*q;
b=x.building;
building=sum(b.*price.building,1);
building_isbl=sum(b.*building_share.*price.building,1);
installed=isbl_eq+osbl_eq+building;isbl=isbl_eq+building_isbl;
if any(embedded>installed+1e-9),error('recovery:Capital','Embedded budgets exceed installation.');end
fixed=installed+(installed-embedded)*(v('engineering_rate')+v('contingency_rate'));
area=sum(x.land,1);land=price.land*area;
n=numel(price.land);
cost.PT=repmat(annual_cost(fixed,v('discount_rate'),v('economic_life'),v('capital_residual_rate'))/utilization,n,1) ...
    +(land+building+(isbl_eq+osbl_eq)*v('property_equipment_share'))*v('property_tax_rate')/utilization;
cost.LD=annual_cost(land,v('discount_rate'),v('economic_life'),v('land_residual_rate'))/utilization ...
    +price.land_tax*area/utilization;
capital=struct('installed',installed,'isbl',isbl);
end

function value=annual_cost(investment,rate,life,residual)
if rate==0,value=investment*(1-residual)/life;
else,d=(1+rate)^(-life);value=investment*(1-residual*d)*rate/(1-d);end
end


function cost = fcop(x, price, parameter, capital, revenue, utilization)
%FCOP Fixed production costs for one compatible plant design.
%   Internal recovery helper. All outputs: city x chemistry, CNY/t pack.
%   Uses acc's investment bases once. Property/land taxes are included in acc.
%   RD follows the approved revenue proxy, not a literal throughput constant.
v=@(name) parameter.factor{name,'value'};
n=numel(price.wage);
staff=x.labor;direct=double(parameter.labor.direct(:));
loaded_direct=price.wage*(direct.'*staff)*(1+v('supervision_rate'))*(1+v('salary_overhead_rate'))/utilization;
loaded_all=price.wage*((1-direct).'*staff)*(1+v('salary_overhead_rate'))/utilization;
cost.LB=loaded_direct+loaded_all;
cost.GA=loaded_direct*v('general_admin_rate');cost.RD=revenue*v('research_rate');
cost.MT=repmat(capital.isbl*v('maintenance_rate')/utilization,n,1);
cost.IS=repmat(capital.installed*v('insurance_rate')/utilization,n,1);
end


function cost = vcop(x, price, names, utilization)
%VCOP Material, utility and disposal costs for one compatible plant design.
%   Internal recovery helper. All outputs: city x chemistry, CNY/t pack.
%   Revenue is kept outside VCOP. Historical UT retains basic electricity
%   charges; domestic disposal follows staffing/design capacity at turndown.
n=numel(price.wage);u=price.utility;
cost.RM=repmat(price.material.'*x.material,n,1);
cost.UT_fixed=price.basic_rate*(12*quantity('power_demand')/utilization);
cost.UT=u.electricity*quantity('electricity')+cost.UT_fixed ...
    +u.natural_gas*quantity('natural_gas')+u.steam*quantity('steam') ...
    +u.fresh_water*quantity('fresh_water');
waste=x.waste;domestic=names.waste=="domestic_waste";
waste(domestic,:)=waste(domestic,:)/utilization;
cost.WD=u.wastewater*quantity('wastewater')+repmat(price.waste.'*waste,n,1);

    function amount=quantity(name)
        j=find(names.utility==name);
        if ~isscalar(j),error('recovery:MissingItem','Expected exactly one utility:%s.',name);end
        amount=x.utility(j,:);
    end
end


function PC = pc(design, names, gap, utility, grid)
%PC Process CO2 and all factory energy burdens, kg CO2e/t pack.
%   Internal recovery helper. Output: city x year x chemistry.
%   All onsite electricity, including environmental equipment, is counted
%   once here. Fuel/steam factors retain their approved supply-chain scope;
%   PC is an activity category, not a GHG Protocol Scope 1 inventory.
fixed=zeros(2,6);electricity=zeros(2,6);
for s=1:2
    x=design{s};
    fixed(s,:)=x.direct_emission(names.direct_emission=="process_co2",:) ...
        +x.utility(names.utility=="natural_gas",:)*utility{'natural_gas','value'} ...
        +x.utility(names.utility=="steam",:)*utility{'steam','value'};
    electricity(s,:)=x.utility(names.utility=="electricity",:);
end
w=gap;
a=reshape(fixed(2,:),1,1,6)+reshape(fixed(1,:)-fixed(2,:),1,1,6).*w;
b=reshape(electricity(2,:),1,1,6)+reshape(electricity(1,:)-electricity(2,:),1,1,6).*w;
PC=a+reshape(grid,size(grid,1),size(grid,2),1).*b;
end


function UM = um(design, names, gap, ghg, utility, grid)
%UM Material and fresh-water supply burdens, kg CO2e/t pack.
%   Internal recovery helper. Output: city x year x chemistry.
%   ghg is already matched to material commodity/active-content basis and
%   aligned to names.material. Apply t-to-kg ONCE; no second purity scaling.
%   Electricity used to produce materials belongs here, not in PC.
%   Material factors retain the boundary limitations of inputs/emission_factor.mat.
fixed=zeros(2,6);electricity=zeros(2,6);
for s=1:2
    x=design{s};mass=x.material*1000;
    fixed(s,:)=ghg.fixed.'*mass ...
        +x.utility(names.utility=="fresh_water",:)*utility{'fresh_water','value'};
    electricity(s,:)=ghg.electricity.'*mass;
end
w=gap;
a=reshape(fixed(2,:),1,1,6)+reshape(fixed(1,:)-fixed(2,:),1,1,6).*w;
b=reshape(electricity(2,:),1,1,6)+reshape(electricity(1,:)-electricity(2,:),1,1,6).*w;
UM=a+reshape(grid,size(grid,1),size(grid,2),1).*b;
end


function WT = wt(design, names, gap, waste, utility, city_count, utilization)
%WT External waste services and terminal carbon policy, kg CO2e/t pack.
%   Internal recovery helper. Output: city x year x chemistry.
%   Delivered waste is t/t pack; factors are kg CO2e/kg delivered waste.
%   Wastewater uses m3/t pack. Direct-carbon entries already use kg CO2e/t.
%   No onsite electricity is added: it is wholly included in PC.
%   Spent-organic service excludes its carbon oxidation, added separately.
%   Residual-organic final CO2 is the approved terminal-fate assumption;
%   this activity allocation does not establish ownership or a Scope number.
fixed=zeros(2,6);
for s=1:2
    x=design{s};mass=x.waste;
    domestic=names.waste=="domestic_waste";
    mass(domestic,:)=mass(domestic,:)/utilization;
    fixed(s,:)=waste.value.'*(mass*1000) ...
        +x.utility(names.utility=="wastewater",:)*utility{'wastewater','value'} ...
        +x.direct_emission(names.direct_emission=="spent_organic_co2",:) ...
        +x.direct_emission(names.direct_emission=="residual_organic_co2",:);
end
w=gap;
value=reshape(fixed(2,:),1,1,6)+reshape(fixed(1,:)-fixed(2,:),1,1,6).*w;
WT=repmat(value,city_count,1,1);
end


function [design, names, chemistry, gap] = recovery_intensity(data, learning_rate, experience, year_count, group)
%RECOVERY_INTENSITY Validate physical endpoints and compute learning weights.
%   Internal recovery helper. design{1}/design{2} are base/floor, each with
%   item x chemistry numeric arrays grouped exactly as the input tables.
%   The learned physical intensity is floor+(base-floor)*gap(t,k).
%   Return endpoints plus 1 x year x chemistry weights, not an item x
%   city x year x chemistry tensor. Recovery prices each endpoint before
%   interpolation, retaining its matched building allocation and exact order.
keys=["equipment";"building";"land";"labor";"material";"utility";"waste";"product";"direct_emission"];
if ~isequal(sort(string(fieldnames(data))),sort(keys))
    error('recovery:Schema','Missing or unexpected physical groups.');
end
if ~isstruct(data.equipment) || ~isfield(data.equipment,'base') || ~istable(data.equipment.base)
    error('recovery:Schema','Equipment base must be a named table.');
end
chemistry=string(data.equipment.base.Properties.VariableNames(:));
if numel(chemistry)~=6,error('recovery:Schema','Expected six chemistry columns.');end
design={struct,struct};names=struct;
for k=1:numel(keys)
    key=keys(k);part=data.(key);
    if ~isstruct(part) || ~isequal(sort(string(fieldnames(part))),["base";"floor"]) || ...
            ~istable(part.base) || ~istable(part.floor) || height(part.base)==0 || ...
            numel(part.base.Properties.RowNames)~=height(part.base) || ...
            ~isequal(part.floor.Properties.RowNames,part.base.Properties.RowNames) || ...
            ~isequal(string(part.base.Properties.VariableNames(:)),chemistry) || ...
            ~isequal(part.floor.Properties.VariableNames,part.base.Properties.VariableNames)
        error('recovery:Schema','Physical base/floor rows and chemistry must agree.');
    end
    names.(key)=string(part.base.Properties.RowNames);
    design{1}.(key)=part.base{:,:};design{2}.(key)=part.floor{:,:};
    values=[design{1}.(key) design{2}.(key)];
    if ~isnumeric(values) || ~isreal(values) || any(~isfinite(values) | values<0,'all')
        error('recovery:Value','physical intensities must be finite and nonnegative.');
    end
end
% Domestic refuse follows total staffing at both learning endpoints. Keep the
% input floor explicit, but reject a future labor edit that leaves it stale.
j=names.waste=="domestic_waste";
staff_base=sum(design{1}.labor,1);staff_floor=sum(design{2}.labor,1);
if nnz(j)~=1 || any(staff_base<=0)
    error('recovery:DomesticWaste','Expected domestic waste and positive baseline staffing.');
end
expected=design{1}.waste(j,:).*staff_floor./staff_base;
if any(abs(design{2}.waste(j,:)-expected)>1e-12*max(1,abs(expected)))
    error('recovery:DomesticWaste','Domestic waste floor must follow the total labor floor/base ratio.');
end
if ~isscalar(learning_rate) || ~isfinite(learning_rate) || learning_rate<0 || learning_rate>=1
    error('recovery:Parameter','Learning rate must be in [0,1).');
end
Q=experience;
if ~isreal(Q) || any(~isfinite(Q) | Q<1,'all')
    error('recovery:Experience','Q/Q0 must be real, finite and >=1.');
end
if isscalar(Q)
    Q=repmat(Q,year_count,2);
elseif isequal(size(Q),[year_count 2])
    % Columns are LFP and non-LFP, respectively.
elseif isrow(Q) && numel(Q)==year_count
    Q=repmat(Q(:),1,2); % Original shared-annual interface.
else
    error('recovery:Experience','Use year x 2, a scalar, or a shared 1 x year row.');
end
if any(diff(Q,1,1)<0,'all')
    error('recovery:Experience','Each experience pool must be nondecreasing.');
end
if ~isequal(sort(chemistry),sort(["LFP";"LMO";"NCM-L";"NCM-M";"NCM-H";"NCA"]))
    error('recovery:Schema','Expected the six named chemistry columns.');
end
[found,index]=ismember(chemistry,string(group.Properties.RowNames));
if ~all(found) || height(group)~=6,error('recovery:Group','Learning chemistry rows differ.');end
pools=unique(string(group.pool),'stable');
if numel(pools)~=2,error('recovery:Group','Expected two experience pools.');end
[~,pool]=ismember(string(group.pool(index)),pools);
gap=reshape((1-learning_rate).^log2(Q(:,pool)),1,year_count,6);
end
