function outflow = retirement(year_start, year_end, options)
%RETIREMENT Read retirement inputs and return collected battery tonnes.
%   Output fields: city_ch, city_en, year, chemistry, mass.
%   mass: city x year x chemistry; collection is already applied.
%   share_start/share_end refer to the optional chemistry-share scenario.
%   Reads inputs/retirement; writes no files.
arguments
    year_start (1,1) double {mustBeFinite,mustBeInteger}
    year_end (1,1) double {mustBeFinite,mustBeInteger}
    options.collection_rate_2040 (1,:) double {mustBeFinite,mustBeReal} = []
    options.median_life (1,:) double {mustBeFinite,mustBePositive} = []
    options.year_cr1 (1,:) double = []
    options.cr1 (1,:) double = []
    options.year_cr2 (1,:) double = []
    options.cr2 (1,:) double = []
    options.shape (1,:) double {mustBeFinite,mustBePositive} = []
    options.density (1,:) double {mustBeFinite,mustBePositive} = []
    options.chemistry (1,1) string = ""
    options.share_start (1,:) double {mustBeFinite,mustBeInteger} = []
    options.share_end (1,:) double {mustBeFinite,mustBeInteger} = []
    options.share_change (1,:) double {mustBeFinite} = []
end
if year_end<year_start,error('retirement:Year','year_end must be >= year_start.');end
version=fileparts(fileparts(mfilename('fullpath')));
t=load(fullfile(version,'inputs','retirement.mat'),'retirement');
if ~isempty(options.collection_rate_2040)
    validateattributes(options.collection_rate_2040,{'double'},{'scalar','>',0,'<',1});
    if (~isempty(options.year_cr2) && options.year_cr2~=2040) || ...
            (~isempty(options.cr2) && options.cr2~=options.collection_rate_2040)
        error('retirement:CollectionConflict','collection_rate_2040 conflicts with year_cr2/cr2.');
    end
    options.year_cr2=2040;options.cr2=options.collection_rate_2040;
end
options=rmfield(options,'collection_rate_2040');
for key=["median_life","shape","year_cr1","cr1","year_cr2","cr2"]
    if isempty(options.(key)),options.(key)=t.retirement.parameter{key,'value'};end
    validateattributes(options.(key),{'double'},{'scalar','real','finite'});
end
for key=["chemistry","share_start","share_end","share_change"]
    if isempty(options.(key)) || (key=="chemistry" && options.chemistry=="")
        options.(key)=t.retirement.scenario.(key);
    end
end
if isempty(options.density)
    d=t.retirement;
    [found,index]=ismember(string(t.retirement.chemistry),string(d.density.Properties.RowNames));
    if ~all(found) || height(d.density)~=numel(index),error('retirement:Density','Density chemistry rows differ.');end
    options.density=d.density.value(index).';
end
options.year=year_start:year_end;
options.year_start=options.share_start;options.year_end=options.share_end;
options=rmfield(options,{'share_start','share_end'});
args=namedargs2cell(options);
outflow=retirement_data(t.retirement,args{:});
end


function outflow = retirement_data(tim, options)
%RETIREMENT_DATA Internal calculation with the loaded TIM structure.
%   outflow = retirement_data(tim) accepts the structure stored in
%   ../inputs/retirement.mat: city, year, chemistry, inflow, density.
%   tim.inflow is a double city x year x six-chemistry array in GWh.
%   This function does not read or write the private source workbook.
%
%   Output fields: city_ch, city_en, year, chemistry, mass.
%   mass is collected pack mass in TONNES, including the collection curve,
%   with city x year x chemistry dimensions. GWh is internal only.
%   Do not multiply the returned quantities by collection_rate a second time.
%
%   Name-value parameters:
%     shape           Weibull shape; default from retirement.parameter.
%     median_life     Median first-use lifetime; default from retirement.parameter.
%     year_cr1, cr1   First collection anchor; defaults from config.
%     year_cr2, cr2   Second collection anchor; defaults from config.
%                     Gompertz curve with fixed asymptotes 0 and 1; applies
%                     in retirement years, including before/after anchors.
%                     Anchors are scenario assumptions, not observations.
%     density         Six pack specific energies in Wh/kg, loaded by the
%                     public wrapper from inputs/retirement.mat (GREET EV300).
%                     NCM-L/M/H use NMC111/622/811 respectively.
%     year            Output years; empty returns all input years. The full
%                     inflow history is used before selecting output years.
%     chemistry       One target: LFP, LMO, NCM-L, NCM-M, NCM-H or NCA.
%                     Required for a nonzero share_change; default empty.
%     year_start      Last unchanged installation year; no default year.
%     year_end        Year reaching the full change; must exceed year_start.
%     share_change    Scalar absolute national total-GWh share change;
%                     default 0. +0.2 means +20 percentage points.
%                     Nonzero changes require chemistry and both years.
%
%   Share changes act on installation cohorts before lifetime calculation.
%   The offset is zero through year_start, ramps linearly to year_end, then
%   stays at full offset from each year's original share. Targets are clipped
%   to [0,1]. The other five chemistries compensate in their original national
%   proportions; each city's total GWh is conserved. Input data is unchanged.
%   The Weibull retirement calculation uses the full installation history.
%   Collection is applied only after retirement and output-year selection.
%   No SOH multiplier is used. The function saves no files.

arguments
    tim (1,1) struct
    options.shape (1,:) double {mustBeFinite,mustBePositive} = []
    options.median_life (1,:) double {mustBeFinite,mustBePositive} = []
    options.year_cr1 (1,:) double {mustBeReal,mustBeFinite,mustBeInteger} = []
    options.cr1 (1,:) double {mustBeReal,mustBeFinite} = []
    options.year_cr2 (1,:) double {mustBeReal,mustBeFinite,mustBeInteger} = []
    options.cr2 (1,:) double {mustBeReal,mustBeFinite} = []
    options.density (1,:) double {mustBeFinite,mustBePositive} = []
    options.year (1,:) double {mustBeFinite,mustBeInteger} = []
    options.chemistry (1,1) string = ""
    options.year_start (1,:) double {mustBeFinite,mustBeInteger} = []
    options.year_end (1,:) double {mustBeFinite,mustBeInteger} = []
    options.share_change (1,:) double {mustBeFinite} = 0
end

if ~all(isfield(tim,{'city','year','chemistry','inflow'}))
    error('retirement:InvalidInflow','tim must provide city, year, chemistry and inflow.');
end
city_ch = string(tim.city.Properties.RowNames);
city_en = string(tim.city.city_en);
if isempty(city_ch) || ~iscolumn(city_ch) || ~iscolumn(city_en) ...
        || numel(city_en)~=numel(city_ch) || numel(unique(city_ch))~=numel(city_ch) ...
        || any(ismissing(city_ch) | strlength(strip(city_ch))==0 | city_ch=="AL") ...
        || any(ismissing(city_en) | strlength(strip(city_en))==0)
    error('retirement:InvalidCities','tim must have matching nonempty city columns and unique city_ch.');
end
if ~isnumeric(tim.year) || ~isreal(tim.year) || ~iscolumn(tim.year) || isempty(tim.year) ...
        || any(~isfinite(tim.year)) || any(tim.year~=fix(tim.year)) || any(diff(tim.year)~=1)
    error('retirement:InvalidSourceYears','tim.year must be a column of consecutive integer years.');
end
year_source = tim.year(:)'; % Row only for cohort calculations; stored coordinates are columns.
chemistry = ["LFP";"LMO";"NCM-L";"NCM-M";"NCM-H";"NCA"];
if ~isequal(string(tim.chemistry),chemistry)
    error('retirement:InvalidChemistry','tim.chemistry must be LFP, LMO, NCM-L, NCM-M, NCM-H, NCA in order.');
end
city_count = numel(city_ch);
year_count = numel(year_source);
chemistry_count = numel(chemistry);
if ~isa(tim.inflow,'double') || ~isreal(tim.inflow) || issparse(tim.inflow) ...
        || ndims(tim.inflow)>3 || size(tim.inflow,1)~=city_count ...
        || size(tim.inflow,2)~=year_count || size(tim.inflow,3)~=chemistry_count ...
        || any(~isfinite(tim.inflow),'all') || any(tim.inflow<0,'all')
    error('retirement:InvalidInflow','tim.inflow must be a finite nonnegative double city x year x six-chemistry array.');
end

share_change = options.share_change;
if ~isscalar(share_change)
    error('retirement:InvalidShareChange','share_change must be a scalar percentage-point change.');
end
target = find(chemistry==options.chemistry);
if ismissing(options.chemistry) || (strlength(options.chemistry)>0 && isempty(target))
    error('retirement:InvalidChemistry','chemistry must be one of: %s.',strjoin(chemistry,', '));
end
if share_change~=0 && isempty(target)
    error('retirement:MissingChemistry','Nonzero share_change requires one chemistry.');
end
if isempty(options.year_start) && isempty(options.year_end)
    if share_change~=0
        error('retirement:MissingShareYears','Nonzero share_change requires year_start and year_end.');
    end
elseif numel(options.year_start)~=1 || numel(options.year_end)~=1 ...
        || options.year_end<=options.year_start ...
        || ~isfinite(options.year_end-options.year_start)
    error('retirement:InvalidShareYears','Provide scalar years with year_end greater than year_start.');
end
density = options.density;
if numel(density)~=chemistry_count
    error('retirement:InvalidDensity','density must provide six Wh/kg values in chemistry order.');
end

% Stack city/chemistry rows to reuse one shared annual retirement kernel.
values = reshape(permute(tim.inflow,[1 3 2]),city_count*chemistry_count,year_count);
if share_change~=0
    values = adjust_share(values,year_source,city_count, ...
        target,options.year_start,options.year_end,share_change);
end
scale = options.median_life / log(2)^(1/options.shape);
kernel = weibull_kernel(year_source,options.shape,scale);
gwh = permute(reshape(values*kernel,city_count,chemistry_count,year_count),[1 3 2]);

if isempty(options.year)
    year = year_source;
else
    year = options.year;
    if any(diff(year)<=0) || ~all(ismember(year,year_source))
        error('retirement:InvalidYears','year must contain increasing, unique years present in the inflow.');
    end
end
[~,year_index] = ismember(year,year_source);
gwh = gwh(:,year_index,:);
rate=collection_rate(year,options.year_cr1,options.cr1,options.year_cr2,options.cr2);
rate=reshape(rate,1,[],1);
% GWh / (Wh/kg) * 10^9 Wh/GWh / 1000 kg/t = GWh / density * 10^6.
mass = gwh ./ reshape(density,1,1,chemistry_count) .* 1e6;
mass = mass .* rate;
outflow = struct('city_ch',city_ch,'city_en',city_en,'year',year(:), ...
    'chemistry',chemistry,'mass',mass);
end


function inflow = adjust_share(inflow,year,city_count,target,year_start,year_end,share_change)
% Work on small city-by-chemistry slices; keep the full cohort history intact.
inflow = reshape(inflow,city_count,6,numel(year));
progress = min(1,max(0,(year-year_start)/(year_end-year_start)));
clipped = false;
for year_index=find(progress>0)
    values = inflow(:,:,year_index);
    total = sum(values,'all');
    if total==0, continue; end
    original_share = sum(values(:,target))/total;
    [values,was_clipped] = redistribute_share(values,target, ...
        original_share+progress(year_index)*share_change);
    clipped = clipped || was_clipped;
    inflow(:,:,year_index) = values;
end
inflow = reshape(inflow,city_count*6,numel(year));
if clipped
    warning('retirement:ShareClipped','One or more national share targets were clipped to [0,1].');
end
end


function [values,clipped] = redistribute_share(values,target,target_share)
clipped = target_share<0 || target_share>1;
target_share = min(1,max(0,target_share));
total = sum(values,'all');
if total==0, return; end
original_share = min(1,max(0,sum(values(:,target))/total));
other = 1:size(values,2);
other(target) = [];
if target_share>original_share
    fraction = min(1,(target_share-original_share)/(1-original_share));
    transfer = fraction*sum(values(:,other),2);
    values(:,other) = (1-fraction)*values(:,other);
    values(:,target) = values(:,target)+transfer;
elseif target_share<original_share
    other_total = sum(values(:,other),'all');
    if other_total==0
        error('retirement:NoCompensation', ...
            'Cannot reduce chemistry %d: the original national compensation group has no composition.',target);
    end
    % National proportions also define compensation for a city with no other chemistry.
    composition = sum(values(:,other),1)/other_total;
    fraction = min(1,(original_share-target_share)/original_share);
    transfer = fraction*values(:,target);
    values(:,target) = (1-fraction)*values(:,target);
    values(:,other) = values(:,other)+transfer.*composition;
end
end


function kernel = weibull_kernel(year,shape,scale)
% Annual cohort convention: no retirement during the installation year.
age = year-year';
kernel = (age>0) .* (exp(-(max(age-1,0)/scale).^shape)-exp(-(max(age,0)/scale).^shape));
end


function rate = collection_rate(year, year_cr1, cr1, year_cr2, cr2)
%COLLECTION_RATE Formal collection scenario from two Gompertz anchors.
%   rate = collection_rate(year,year_cr1,cr1,year_cr2,cr2) overrides them.
%   Output: 1 x year, unitless. Fixed asymptotes are 0 and 1.
%   The curve extends on both sides of the anchors; it is NOT capped at cr2.
%   These anchors define a scenario, not an estimated historical time series.
%   No file I/O or persistent parameters; apply once to retirement-year mass.
arguments
    year (1,:) double {mustBeReal,mustBeFinite,mustBeInteger,mustBeNonempty}
    year_cr1 (1,1) double {mustBeReal,mustBeFinite,mustBeInteger}
    cr1 (1,1) double {mustBeReal,mustBeFinite}
    year_cr2 (1,1) double {mustBeReal,mustBeFinite,mustBeInteger}
    cr2 (1,1) double {mustBeReal,mustBeFinite}
end
if year_cr2<=year_cr1 || ~isfinite(year_cr2-year_cr1) || ~(0<cr1 && cr1<cr2 && cr2<1)
    error('collection_rate:InvalidAnchors','Require year_cr1 < year_cr2 and 0 < cr1 < cr2 < 1.');
end
z1=log(-log(cr1));z2=log(-log(cr2));
b=(z1-z2)/(year_cr2-year_cr1);
rate=exp(-exp(z1-b*(year-year_cr1)));
% Preserve the user-supplied anchors exactly, including their last bit.
rate(year==year_cr1)=cr1;rate(year==year_cr2)=cr2;
end
