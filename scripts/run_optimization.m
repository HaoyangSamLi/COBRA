function [optimization_result, folder] = run_optimization(config, outflow, assessment_result, logistics_result, baseline, auxiliary, options)
%RUN_OPTIMIZATION Bind supplied assessment outputs; solve only with solve=true.
%   No retirement, recovery or logistics calculations are repeated here.
%   Default: prepare files and return []; save optimization_result.mat only
%   after explicit execution. Two reference endpoints, cost-corrected emission endpoint and epsilon points; no retries.
arguments
    config (1,1) struct
    outflow (1,1) struct
    assessment_result (1,1) struct
    logistics_result (1,1) struct
    baseline (1,1) struct
    auxiliary (1,1) struct
    options.solve (1,1) logical = false
    options.folder (1,1) string = ""
    options.ampl (1,1) string = "ampl"
    options.solver (1,1) string = "gurobi"
end
version=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(version,'src'));
s=load(fullfile(version,'inputs','optimization.mat'));p=s.optimization;
r=load(fullfile(version,'inputs','recovery.mat'));r=r.recovery;
% All optimization coefficients are normalized to full design utilization.
% Capacity/throughput allocation is performed by the optimization model once.
if r.scenario.utilization~=1
    error('run_optimization:Utilization','Optimization requires input utilization=1; do not pre-scale unit coefficients.');
end
data=bind_data(p,r,config,outflow,assessment_result,logistics_result,baseline,auxiliary);
clear outflow assessment_result logistics_result baseline auxiliary p r
args=namedargs2cell(options);
[optimization_result,folder]=optimization(data,args{:});
if options.solve && all(optimization_result.summary.status=="solved")
    output=fullfile(version,'outputs');if ~isfolder(output),mkdir(output);end
    save(fullfile(output,'optimization_result.mat'),'optimization_result','-v7.3');
end
end

function data=bind_data(p,r,config,o,a,l,b,auxiliary)
city=o.city_ch(:);chemistry=o.chemistry(:);year=o.year(:);
if numel(unique(city))~=numel(city)||numel(unique(chemistry))~=6
    error('run_optimization:Coordinates','Expected unique cities and six chemistries.');
end
data=struct;
data.city=table(o.city_en(:),'VariableNames',{'city_en'},'RowNames',cellstr(city));
data.year=year;data.chemistry=chemistry;data.scenario=config;
data.parameter=p.parameter;
data.solver=p.solver;
data.life=r.parameter.factor{'economic_life','value'};
data.actor=p.city.actor(match(city,string(p.city.Properties.RowNames)));
data.initial_capacity=p.capacity{match(city,string(p.capacity.Properties.RowNames)), ...
    match(chemistry,string(p.capacity.Properties.VariableNames))};
data.outflow=o.mass;
ai=match(city,string(a.city.Properties.RowNames));ak=match(chemistry,a.chemistry);ay=match(year,a.year);
bi=match(city,string(b.city.Properties.RowNames));bk=match(chemistry,b.chemistry);
if ~isequal(b.year,p.parameter{'base_year','value'})
    error('run_optimization:BaseYear','Existing-asset coefficients must be from the base year.');
end
data.vintage=[b.year;year];
for name=["PT","LD","MT","IS"]
    data.(name)=cat(2,b.(name)(bi,:,bk),a.(name)(ai,ay,ak));
end
for name=["LB","GA","RM","UT","WD","RD","PC","UM","WT"]
    data.(name)=a.(name)(ai,ay,ak);
end
if ~isfield(auxiliary,'UT_fixed') || ~isequal(size(auxiliary.UT_fixed),size(a.UT))
    error('run_optimization:Utility','The internal fixed-electricity coefficients must align with assessment UT.');
end
data.UT_fixed=auxiliary.UT_fixed(ai,ay,ak);
li=match(city,l.city_ch);ly=match(year,l.year);
data.LC=l.cost(li,li,ly);data.LE=l.emission(li,li,ly);
data.price_rate=l.price_rate(li,li);
data.BT=l.battery{match(chemistry,string(l.battery.Properties.RowNames)),'price'};
% USD and t CO2e conversion is guaranteed at the public recovery boundary.
end

function index=match(target,source)
target=string(target(:));source=string(source(:));
[found,index]=ismember(target,source);
if numel(unique(source))~=numel(source)||~all(found)||numel(target)~=numel(source)
    error('run_optimization:Coordinates','Coordinate labels must be unique and cover the same entries.');
end
end
