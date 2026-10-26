function [outflow, assessment_result, logistics_result, baseline, auxiliary] = run_assessment(config)
%RUN_ASSESSMENT Calculate a resolved scenario and save its factory assessment.
%   Called by run_scenario after defaults/overrides are resolved. No optimizer
%   is called here. baseline carries base-year asset coefficients in memory.
%   outflow: tonnes; factory/logistics cost: USD/t pack; emissions: t CO2e/t.
%   Learning pools use fixed historical Q0 and experience through year t-1.
arguments
    config (1,1) struct
end
version=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(version,'src'));
loaded=load(fullfile(version,'inputs','optimization.mat'),'optimization');
window=config.window;
% Window is (year_start, year_end]; process functions retain inclusive years.
year_start=window(1)+1;year_end=window(2);
if year_end>2060,error('run_assessment:Year','Accounting is supported through 2060.');end
p=load(fullfile(version,'inputs','recovery.mat'),'recovery');
learning=p.recovery.learning;
base_year=learning.factor{'base_year','value'};
history_start=learning.factor{'history_start','value'};
validateattributes(base_year,{'double'},{'scalar','finite','integer'});
validateattributes(history_start,{'double'},{'scalar','finite','integer','<',base_year});
if year_start<base_year,error('run_assessment:Year','Accounting must start at or after learning base_year.');end
% Include all experience since base_year even if the requested window is later.
outflow=retirement(base_year,year_end,median_life=config.median_life, ...
    collection_rate_2040=config.collection_rate_2040);
historical=retirement(history_start,base_year-1); % Fixed baseline, no future overrides.
experience=learning_experience(outflow,historical,learning);
selected=outflow.year>=year_start;
experience=experience(selected,:);
outflow.year=outflow.year(selected);outflow.mass=outflow.mass(:,selected,:);
clear historical p learning selected
[assessment_result,auxiliary]=recovery(year_start,year_end,experience=experience, ...
    learning_rate=config.learning_rate,scenario=config.grid_case,metal_price_case=config.metal_price_case);
assessment_result.scenario=struct('median_life',config.median_life, ...
    'collection_rate_2040',config.collection_rate_2040,'learning_rate',config.learning_rate, ...
    'metal_price_case',config.metal_price_case,'grid_case',config.grid_case);
clear experience
logistics_result=logistics(year_start,year_end,scenario=config.grid_case, ...
    transport_multiplier=config.transport_multiplier, ...
    electric_share_2040=config.electric_share_2040,metal_price_case=config.metal_price_case);
% Check named coordinates before run_optimization binds numeric arrays.
% BRACE's stored order is intentionally preserved; never match by row number.
target=outflow.city_ch(:);
for source={string(assessment_result.city.Properties.RowNames),logistics_result.city_ch, ...
        string(loaded.optimization.city.Properties.RowNames), ...
        string(loaded.optimization.capacity.Properties.RowNames)}
    keys=string(source{1}(:));
    [found,index]=ismember(target,keys);
    if numel(keys)~=numel(target) || numel(unique(keys))~=numel(keys) || ...
            ~all(found) || ~isequal(keys(index),target)
        error('run_assessment:City','All accounting and capacity tables must cover the same unique city names.');
    end
end
if ~isequal(string(loaded.optimization.capacity.Properties.VariableNames),outflow.chemistry(:)')
    error('run_assessment:Chemistry','Initial capacity chemistry columns must match the accounting chemistry order.');
end
% Existing assets use base-year design coefficients, outside decision years.
asset_year=loaded.optimization.parameter{'base_year','value'};
baseline=recovery(asset_year,asset_year,experience=1,utilization=1, ...
    metal_price_case=config.metal_price_case,scenario=config.grid_case);
output_folder=fullfile(version,'outputs');
if ~isfolder(output_folder),mkdir(output_folder);end
save(fullfile(output_folder,'assessment_result.mat'),'assessment_result','-v7.3');
end

function experience=learning_experience(outflow,historical,learning)
% Accumulate in tonnes before selecting the requested accounting window.
if ~isequal(outflow.chemistry,historical.chemistry) || ...
        ~isequal(outflow.chemistry,["LFP";"LMO";"NCM-L";"NCM-M";"NCM-H";"NCA"]) || ...
        ~isequal(historical.year(:)',learning.factor{'history_start','value'}:learning.factor{'base_year','value'}-1) || ...
        outflow.year(1)~=learning.factor{'base_year','value'}
    error('run_assessment:Experience','Expected complete baseline history and six aligned chemistries.');
end
annual_mass=reshape(sum(outflow.mass,1),numel(outflow.year),6);
[found,index]=ismember(outflow.chemistry,string(learning.group.Properties.RowNames));
if ~all(found) || height(learning.group)~=6,error('run_assessment:Group','Learning chemistry rows differ.');end
pool=string(learning.group.pool(index));
pools=unique(string(learning.group.pool),'stable');
if numel(pools)~=2,error('run_assessment:Group','Expected two experience pools.');end
q=sum(reshape(sum(historical.mass,1),numel(historical.year),6),1);
pooled=zeros(size(annual_mass,1),2);q0=zeros(1,2);
for k=1:2
    selected=pool==pools(k);
    pooled(:,k)=sum(annual_mass(:,selected),2);q0(k)=sum(q(selected));
end
annual_mass=pooled;
if any(~isfinite(q0) | q0<=0)
    error('run_assessment:Experience','Both historical experience pools must be finite and positive.');
end
previous=[zeros(1,2);cumsum(annual_mass(1:end-1,:),1)];
experience=(q0+previous)./q0;
end
