function [outflow, assessment_result, logistics_result, optimization_result, folder] = run_scenario(config, options)
%RUN_SCENARIO Resolve one scenario, assess it once, then prepare optimization.
%   Default: read configs/scenario.mat, save assessment_result.mat and prepare
%   optimization files only. solve=true explicitly enables solver execution.
%   The original first three outputs and their units/dimensions are unchanged.
%   Inputs remain read-only; all overrides are applied in memory.
arguments
    config = []
    options.solve (1,1) logical = false
    options.folder (1,1) string = ""
    options.ampl (1,1) string = "ampl"
    options.solver (1,1) string = "gurobi"
end
version=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(version,'src'));
if isempty(config),config=fullfile(version,'configs','scenario.mat');end
if ischar(config) || (isstring(config) && isscalar(config))
    loaded=load(config,'scenario');
    if ~isfield(loaded,'scenario'),error('run_scenario:Config','Missing scenario variable.');end
    config=loaded.scenario;
end
keys={'window','mode','median_life', ...
    'collection_rate_2040','learning_rate','transport_multiplier', ...
    'electric_share_2040','metal_price_case','grid_case'};
if ~isstruct(config) || ~isscalar(config) || ~isequal(sort(fieldnames(config)),sort(keys(:)))
    error('run_scenario:Config','Use exactly the nine documented scenario fields.');
end
% Resolve empty configuration entries once, without writing input defaults.
loaded=load(fullfile(version,'inputs','optimization.mat'),'optimization');
if isempty(config.window)
    config.window=loaded.optimization.window;
end
window=config.window;
validateattributes(window,{'double'},{'real','finite','integer','size',[2 1]});
if window(1)<loaded.optimization.parameter{'base_year','value'} || window(2)<=window(1) || window(2)>2060
    error('run_scenario:Window','Use base_year <= year_start < year_end <= 2060; start is excluded.');
end
if isempty(config.mode) || (isscalar(string(config.mode)) && strlength(string(config.mode))==0)
    config.mode=loaded.optimization.mode;
end
mustBeMember(string(config.mode),["","greenfield","brownfield"]);
if ~isscalar(string(config.mode)),error('run_scenario:Mode','mode must be scalar.');end
for key=keys(3:7)
    if ~isempty(config.(key{1})),validateattributes(config.(key{1}),{'double'},{'scalar','real','finite'});end
end
if ~isscalar(string(config.metal_price_case)) || ~isscalar(string(config.grid_case))
    error('run_scenario:Selection','Selectors must be scalar.');
end
mustBeMember(string(config.metal_price_case),["low","base","high"]);
if strlength(string(config.grid_case))==0,error('run_scenario:Grid','Select a grid scenario.');end
r=load(fullfile(version,'inputs','recovery.mat'));r=r.recovery;
t=load(fullfile(version,'inputs','retirement.mat'));t=t.retirement;
l=load(fullfile(version,'inputs','logistics.mat'));l=l.logistics;
defaults=struct('median_life',t.parameter{'median_life','value'}, ...
    'collection_rate_2040',t.parameter{'cr2','value'}, ...
    'learning_rate',r.learning.factor{'learning_rate','value'}, ...
    'transport_multiplier',l.scenario.transport_multiplier, ...
    'electric_share_2040',l.trend{'electric_share','value_end'});
for name=string(fieldnames(defaults))'
    if isempty(config.(name)),config.(name)=defaults.(name);end
end
[outflow,assessment_result,logistics_result,baseline,auxiliary]=run_assessment(config);
args=namedargs2cell(options);
[optimization_result,folder]=run_optimization( ...
    config,outflow,assessment_result,logistics_result,baseline,auxiliary,args{:});
clear baseline auxiliary args
end
