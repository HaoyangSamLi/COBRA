function [result, folder] = optimization(data, options)
%OPTIMIZATION Export a standard AMPL problem and optionally execute its frontier.
%   solve=false writes model.dat, execution_settings.json and check.run only.
%   solve=true executes two reference endpoints, one allowed cost correction, then interior points.
%   Solver settings come from inputs/optimization.solver (default 4 x 4).
%   Each cold solve releases AMPL after NL compilation, then restores its
%   solution. Only the verified emission endpoint seeds its approved cost correction.
%   Only fixed candidate indexing and exact constant aggregation are applied.
%   Result coordinates are shared; no four-dimensional flow array is saved.
arguments
    data (1,1) struct
    options.solve (1,1) logical = false
    options.folder (1,1) string = ""
    options.ampl (1,1) string = "ampl"
    options.solver (1,1) string = "gurobi"
end
validate_data(data);
step=data.parameter{'epsilon','value'};
progress=(0:step:1)';
if progress(end)<1-1e-12,progress(end+1)=1;else,progress(end)=1;end
if options.folder==""
    folder=string(tempname);
else
    folder=options.folder;
end
if isfolder(folder)
    entries=dir(folder);entries=entries(~ismember({entries.name},{'.','..'}));
    if ~isempty(entries),error('optimization:Folder','Use a new or empty working folder.');end
else
    mkdir(folder);
end
[ok,info]=fileattrib(folder);assert(ok);folder=string(info.Name);
copyfile(fullfile(fileparts(mfilename('fullpath')),'optimization.mod'),fullfile(folder,'model.mod'));
write_data(data,fullfile(folder,'model.dat'));
write_controls(data,progress,folder);
result=[];
if ~options.solve,return,end
execute_frontier(data,progress,folder,options.ampl,options.solver);
result=read_result(data,progress,folder);
if any(result.summary.status~="solved")
    warning('optimization:Incomplete','Frontier stopped without retries. See summary.status and working files.');
end
end

function validate_data(d)
n=height(d.city);t=numel(d.year);k=numel(d.chemistry);
if n<1||k~=6||~iscolumn(d.year)||~iscolumn(d.chemistry)||any(diff(d.year)~=1)|| ...
        numel(unique(d.city.Properties.RowNames))~=n||numel(unique(d.chemistry))~=k
    error('optimization:Coordinates','Expected unique named cities, six chemistries and consecutive years.');
end
keys={'base_year';'mip_gap';'epsilon';'throughput_share_max';'minimum_capacity';'discount_cost';'discount_rate';'endpoint_emission_allowance'};
if ~isequal(d.parameter.Properties.RowNames,keys)|| ...
        ~isequal(d.parameter.Properties.VariableNames,{'value'})|| ...
        any(~isfinite(d.parameter.value)|d.parameter.value<0)
    error('optimization:Parameter','Use the eight named, finite optimization parameters.');
end
p=@(key)d.parameter{key,'value'};
solver_keys={'parallel_tasks';'threads';'ampl_presolve';'gurobi_presolve'; ...
    'endpoint_method';'intermediate_method';'correction_presolve'; ...
    'correction_method';'correction_warm_start';'projection_method'};
if ~istable(d.solver)||~isequal(d.solver.Properties.RowNames,solver_keys)|| ...
        ~isequal(d.solver.Properties.VariableNames,{'value'})|| ...
        ~isa(d.solver.value,'double')||any(~isfinite(d.solver.value))|| ...
        any(d.solver.value~=fix(d.solver.value))|| ...
        any(d.solver{solver_keys(1:2),'value'}<1)|| ...
        d.solver{'ampl_presolve','value'}<0|| ...
        ~ismember(d.solver{'gurobi_presolve','value'},-1:2)|| ...
        any(~ismember(d.solver{solver_keys([5 6 8 10]),'value'},-1:5))|| ...
        ~ismember(d.solver{'correction_presolve','value'},-1:2)|| ...
        ~ismember(d.solver{'correction_warm_start','value'},[0 1])
    error('optimization:SolverSettings','Use the ten named solver settings with valid integer values.');
end
validateattributes(d.life,{'double'},{'scalar','finite','positive','integer'});
if p('base_year')~=fix(p('base_year'))||p('mip_gap')>=1||p('endpoint_emission_allowance')>=1|| ...
        p('epsilon')<=0||p('epsilon')>1||p('throughput_share_max')<=0|| ...
        p('throughput_share_max')>1||~ismember(p('discount_cost'),[0 1])|| ...
        d.year(1)<=p('base_year')||d.year(end)>2060|| ...
        ~isequal(d.vintage,[p('base_year');d.year])|| ...
        ~isequal(d.scenario.window,[d.year(1)-1;d.year(end)])
    error('optimization:Parameter','Invalid control values, vintages or optimization window.');
end
mustBeMember(string(d.scenario.mode),["brownfield","greenfield"]);
check_array(d.actor,[n 1],'actor');
if any(~ismember(d.actor,[0 1])),error('optimization:Actor','actor must be binary.');end
check_array(d.initial_capacity,[n k],'initial_capacity');
if any(sum(d.initial_capacity(d.actor==0,:),2)>0)
    error('optimization:Capacity','Initial capacity exists outside the candidate-city set.');
end
for key=["outflow","LB","GA","RM","UT","WD","RD","UT_fixed","PC","UM","WT"]
    check_array(d.(key),[n t k],key);
end
for key=["PT","LD","MT","IS"]
    check_array(d.(key),[n t+1 k],key);
end
for key=["LC","LE"],check_array(d.(key),[n n t],key);end
check_array(d.price_rate,[n n],'price_rate');check_array(d.BT,[k 1],'BT');
if any(d.UT_fixed>d.UT,'all'),error('optimization:Utility','UT_fixed exceeds UT.');end
end

function check_array(x,shape,label)
if ~(isnumeric(x)||islogical(x))||~isreal(x)||any(~isfinite(x)|x<0,'all')|| ...
        ~isequal(arrayfun(@(j)size(x,j),1:numel(shape)),shape)
    error('optimization:Data','Invalid size or values for %s.',label);
end
end

function write_data(d,path)
fid=fopen(path,'w');assert(fid>=0);close_file=onCleanup(@()fclose(fid));
n=height(d.city);k=numel(d.chemistry);candidate=find(d.actor==1);
fprintf(fid,'data;\nset city :=');fprintf(fid,' %d',1:n);fprintf(fid,';\nset chemistry :=');
fprintf(fid,' %d',1:k);fprintf(fid,';\n');
for key=["base_year","throughput_share_max","minimum_capacity","discount_cost","discount_rate"]
    fprintf(fid,'param %s := %.17g;\n',key,d.parameter{key,'value'});
end
fprintf(fid,'param year_start := %d;\nparam year_end := %d;\nparam life := %d;\n',d.year(1)-1,d.year(end),d.life);
fprintf(fid,'param mode := "%s";\nparam use_epsilon := 0;\nparam emission_limit := 0;\n',d.scenario.mode);
fprintf(fid,'param actor :=\n');fprintf(fid,'%d %.17g\n',[(1:n);d.actor']);fprintf(fid,';\n');
matrix('initial_capacity',d.initial_capacity,1:n,1:k);
matrix('price_rate',d.price_rate(:,candidate),1:n,candidate);
fprintf(fid,'param BT :=\n');fprintf(fid,'%d %.17g\n',[(1:k);d.BT']);fprintf(fid,';\n');
for name=["PT","LD","MT","IS"],tensor(name,d.(name),1:n,d.vintage,1:k);end
for name=["outflow","LB","GA","RM","UT","WD","RD","UT_fixed","PC","UM","WT"]
    tensor(name,d.(name),1:n,d.year,1:k);
end
for name=["LC","LE"],tensor(name,d.(name)(:,candidate,:),1:n,candidate,d.year);end
route_cost=zeros(n,numel(candidate),numel(d.year));route_emission=route_cost;
for y=1:numel(d.year)
    q=reshape(d.outflow(:,y,:),n,k);
    variable=reshape(d.RM(candidate,y,:)+d.UT(candidate,y,:)-d.UT_fixed(candidate,y,:) ...
        +d.WD(candidate,y,:)+d.RD(candidate,y,:),numel(candidate),k);
    factor=reshape(d.PC(candidate,y,:)+d.UM(candidate,y,:)+d.WT(candidate,y,:),numel(candidate),k);
    route_cost(:,:,y)=q*variable'+d.LC(:,candidate,y).*sum(q,2) ...
        +d.price_rate(:,candidate).*(q*d.BT);
    route_emission(:,:,y)=q*factor'+d.LE(:,candidate,y).*sum(q,2);
end
tensor('route_cost',route_cost,1:n,candidate,d.year);
tensor('route_emission',route_emission,1:n,candidate,d.year);
    function matrix(name,x,rows,cols)
        [i,j]=ndgrid(rows,cols);
        fprintf(fid,'param %s :=\n',name);
        fprintf(fid,'%d %d %.17g\n',[i(:)';j(:)';x(:)']);fprintf(fid,';\n');
    end
    function tensor(name,x,rows,cols,slices)
        [i,j]=ndgrid(rows,cols);
        fprintf(fid,'param %s :=\n',name);
        for z=1:numel(slices)
            part=x(:,:,z);
            fprintf(fid,'%d %d %d %.17g\n',[i(:)';j(:)';repmat(slices(z),1,numel(i));part(:)']);
        end
        fprintf(fid,';\n');
    end
end

function execute_frontier(d,progress,folder,ampl,solver)
% One bounded task queue using the Windows .NET process API.
ampl=executable_path(ampl);solver=executable_path(solver);
count=numel(progress);started=tic;
[raw,timing]=run_points(d,progress,folder,[1 count],ampl,solver,NaN,NaN);
write_summary(raw,timing);
gap=d.parameter{'mip_gap','value'};
good=raw.result_num>=0 & raw.result_num<100 & ...
    isfinite(raw.discounted_cost) & isfinite(raw.emission) & ...
    isfinite(raw.mip_gap) & raw.mip_gap<=gap+1e-12;
if all(good)
    high=raw.emission(raw.point==1);low=raw.emission(raw.point==count);
    if low<=high
        reference=read_result(d,progress,folder);
        % 0.01% is an approved emission allowance, independent of cost MIPGap.
        allowance=d.parameter{'endpoint_emission_allowance','value'};
        cap=min(high,low*(1+allowance));
        [corrected,correction_time]=correct_endpoint(d,progress,folder,ampl,solver,reference,cap);
        meta=struct('minimum_emission_reference',low,'emission_cap',cap, ...
            'emission_allowance',allowance,'emission_at_min_cost',high, ...
            'definition',"Cost minimum subject to the approved near-minimum emission budget");
        fid=fopen(fullfile(folder,'endpoint_reference.json'),'w');assert(fid>=0);
        fprintf(fid,'%s',jsonencode(meta,PrettyPrint=true));fclose(fid);
        raw(raw.point==count,:)=corrected;
        timing=[timing;correction_time];write_summary(raw,timing);
        low=cap;
        clear reference
        if count>2
            [middle,middle_timing]=run_points(d,progress,folder,2:count-1,ampl,solver,high,low);
            raw=[raw;middle];timing=[timing;middle_timing];write_summary(raw,timing);
        end
    else
        warning('optimization:Endpoints','Endpoint order failed; intermediate points were not run.');
    end
end
fprintf('COBRA frontier execution: %.3f s (%d task(s) x %d thread(s)).\n', ...
    toc(started),d.solver{'parallel_tasks','value'},d.solver{'threads','value'});
    function write_summary(rows,times)
        rows=sortrows(rows,'point');times=sortrows(times,'point');
        fid=fopen(fullfile(folder,'summary.csv'),'w');assert(fid>=0);
        closer=onCleanup(@()fclose(fid));
        fprintf(fid,'point,status,result_num,discounted_cost,emission,mip_gap\n');
        for z=1:height(rows)
            fprintf(fid,'%d,%s,%d,%.17g,%.17g,%.17g\n',rows.point(z),rows.status(z), ...
                rows.result_num(z),rows.discounted_cost(z),rows.emission(z),rows.mip_gap(z));
        end
        clear closer
        fid=fopen(fullfile(folder,'execution.csv'),'w');assert(fid>=0);
        closer=onCleanup(@()fclose(fid));
        fprintf(fid,'point,compile_seconds,solver_seconds,restore_seconds,total_seconds\n');
        fprintf(fid,'%d,%.17g,%.17g,%.17g,%.17g\n',times{:,:}');
    end
end

function [rows,timing]=run_points(d,progress,folder,points,ampl,solver,high,low)
% A task owns one process at a time: compile -> native solve -> restore.
% Cleanup terminates only child process trees owned by this invocation.
active=struct('point',{},'stage',{},'process',{},'slot',{},'clock',{}, ...
    'stage_clock',{},'duration',{},'directory',{},'settings',{});
rows=table;timing=table;next=1;
owned=java.util.ArrayList;
cleanup=onCleanup(@()stop_processes(owned));
while next<=numel(points)||~isempty(active)
    while next<=numel(points)&&numel(active)<d.solver{'parallel_tasks','value'}
        point=points(next);next=next+1;
        directory=fullfile(folder,sprintf('point_%d',point));mkdir(directory);
        settings=solver_options(d,point,numel(progress));
        write_point(d,progress,directory,point,solver,high,low,settings);
        item=struct('point',point,'stage',1,'process',[],'slot',owned.size(),'clock',tic, ...
            'stage_clock',tic,'duration',zeros(1,3),'directory',directory,'settings',settings);
        item.process=launch_process([ampl,"compile.run"],directory,settings);
        owned.add(java.lang.Long(int64(item.process.Id)));
        active(end+1)=item; %#ok<AGROW>
        fprintf('COBRA point %d/%d: started.\n',point,numel(progress));
    end
    for j=numel(active):-1:1
        if ~active(j).process.HasExited,continue,end
        owned.set(active(j).slot,java.lang.Long(int64(0)));
        active(j).duration(active(j).stage)=toc(active(j).stage_clock);
        if active(j).process.ExitCode~=0
            error('optimization:Execution','Point %d stage %d failed. Inspect %s.', ...
                active(j).point,active(j).stage,fullfile(active(j).directory,'ampl.log'));
        end
        if active(j).stage<3
            active(j).stage=active(j).stage+1;
            if active(j).stage==2,command=[solver,"problem","-AMPL"];
            else,command=[ampl,"restore.run"];end
            active(j).stage_clock=tic;
            active(j).process=launch_process(command,active(j).directory,active(j).settings);
            active(j).slot=owned.size();
            owned.add(java.lang.Long(int64(active(j).process.Id)));
        else
            log=fileread(fullfile(active(j).directory,'ampl.log'));
            path=fullfile(active(j).directory,'summary.csv');
            if ~isfile(path)||~(contains(log,'COBRA_FINISHED')||contains(log,'COBRA_STOPPED'))
                error('optimization:Execution','Point %d did not export a solver status. Inspect %s.', ...
                    active(j).point,active(j).directory);
            end
            row=readtable(path,'TextType','string');
            if height(row)~=1||row.point~=active(j).point
                error('optimization:Execution','Invalid point summary in %s.',path);
            end
            rows=[rows;row]; %#ok<AGROW>
            times=array2table([active(j).point,active(j).duration,toc(active(j).clock)], ...
                'VariableNames',{'point','compile_seconds','solver_seconds','restore_seconds','total_seconds'});
            timing=[timing;times]; %#ok<AGROW>
            fprintf('COBRA point %d/%d: %s, %.3f s.\n',active(j).point,numel(progress), ...
                row.status,times.total_seconds);
            active(j)=[];
        end
    end
    if ~isempty(active),pause(.2);end
end
clear cleanup
end

function stop_processes(owned)
% Recorded IDs are cleared as soon as their process exits, so an old ID
% cannot later identify an unrelated process after Windows reuses it.
for z=0:owned.size()-1
    id=double(owned.get(z));
    if id>0,system(sprintf('taskkill /PID %.0f /T /F >NUL 2>&1',id));end
end
end

function process=launch_process(command,directory,settings)
if ~ispc,error('optimization:Platform','This process executor requires Windows MATLAB.');end
NET.addAssembly('System');
info=System.Diagnostics.ProcessStartInfo;
info.FileName=getenv('COMSPEC');info.WorkingDirectory=char(directory);
quoted=cellfun(@(x)['"' x '"'],cellstr(command),'UniformOutput',false);
info.Arguments=['/d /s /v:off /c "' strjoin(quoted,' ') ' >> "ampl.log" 2>&1"'];
info.UseShellExecute=false;info.CreateNoWindow=true;info.RedirectStandardInput=true;
environment=info.EnvironmentVariables;
environment.Remove('gurobi_options');environment.Add('gurobi_options',char(settings));
process=System.Diagnostics.Process;process.StartInfo=info;
assert(process.Start());process.StandardInput.Close();
end

function path=executable_path(value)
% Resolve the executable once before changing child working directories.
value=char(value);
if any(ismember(value,[char(34),char(39),'%',newline,char(13)]))
    error('optimization:Executable','Invalid executable path.');
end
names=string(value);[parent,~,extension]=fileparts(value);
if ispc&&extension=="",names=[names,names+".exe"];end
folders=string(pwd);
if isempty(parent),folders=[folders;split(string(getenv('PATH')),pathsep)];end
for folder=folders(:)'
    for name=names
        if isempty(parent),candidate=fullfile(folder,name);else,candidate=name;end
        if isfile(candidate)
            [ok,info]=fileattrib(candidate);assert(ok);path=string(info.Name);return
        end
    end
end
error('optimization:Executable','Executable %s was not found. Supply its full path.',value);
end

function settings=solver_options(d,point,count)
if ismember(point,[1 count]),method=d.solver{'endpoint_method','value'};
else,method=d.solver{'intermediate_method','value'};end
presolve=d.solver{'gurobi_presolve','value'};start=0;
if isfield(d,'endpoint_correction') && d.endpoint_correction
    method=d.solver{'correction_method','value'};
    presolve=d.solver{'correction_presolve','value'};
    start=d.solver{'correction_warm_start','value'};
end
settings=sprintf(['mip:gap=%.17g mip:return_gap=3 alg:start=%d mip:start=%d alg:basis=0 ' ...
    'tech:timing=2 tech:outlev=1 tech:threads=%d pre:solve=%d alg:method=%d'], ...
    d.parameter{'mip_gap','value'},start,start,d.solver{'threads','value'},presolve,method);
end

function write_point(d,progress,directory,point,solver,high,low,settings)
% Shared model/data are regenerated for this scenario, never reused from
% historical experiments. Both AMPL stages select the same objective/budget.
for stage=["compile","restore"]
    fid=fopen(fullfile(directory,stage+".run"),'w');assert(fid>=0);
    closer=onCleanup(@()fclose(fid));
    fprintf(fid,"reset;\noption presolve %d;\nsuffix relmipgap OUT;\noption solver '%s';\n", ...
        d.solver{'ampl_presolve','value'},replace(solver,"\","/"));
    fprintf(fid,"option gurobi_options '%s';\n",settings);
    fprintf(fid,"model '../model.mod';\ndata '../model.dat';\nparam emission_at_min_cost;\nparam minimum_emission;\n");
    fprintf(fid,"printf 'point,status,result_num,discounted_cost,emission,mip_gap\\n' > 'summary.csv';\n");
    correction=isfield(d,'endpoint_correction') && d.endpoint_correction;
    if correction,fprintf(fid,"data '../residual.dat';\n");end
    if correction,objective='min_cost';fprintf(fid,'let use_epsilon := 1;\nlet emission_limit := %.17g;\n',low);
    elseif point==1,objective='min_cost';fprintf(fid,'let use_epsilon := 0;\n');
    elseif point==numel(progress),objective='min_emission';fprintf(fid,'let use_epsilon := 0;\n');
    else
        objective='min_cost';
        fprintf(fid,'let emission_at_min_cost := %.17g;\nlet minimum_emission := %.17g;\n',high,low);
        fprintf(fid,'let use_epsilon := 1;\nlet emission_limit := emission_at_min_cost - %.17g*(emission_at_min_cost-minimum_emission);\n',progress(point));
    end
    fprintf(fid,'objective %s;\n',objective);
    if stage=="compile"
        if correction && d.solver{'correction_warm_start','value'}==1,fprintf(fid,"include '../seed.run';\n");end
        fprintf(fid,'write gproblem;\n');clear closer;continue
    end
    fprintf(fid,'solution problem.sol;\n');
    fprintf(fid,"if solve_result_num >= 100 then {\n printf '%d,%%s,%%d,NaN,NaN,NaN\\n',solve_result,solve_result_num >> 'summary.csv';\n printf 'COBRA_STOPPED\\n'; exit;\n}\n",point);
    fprintf(fid,"printf '%d,%%s,%%d,%%.17g,%%.17g,%%.17g\\n',solve_result,solve_result_num,min_cost.val,min_emission.val,%s.relmipgap >> 'summary.csv';\n",point,objective);
    fprintf(fid,"if %s.relmipgap > %.17g then {printf 'COBRA_STOPPED gap_not_met\\n'; exit;}\n",objective,d.parameter{'mip_gap','value'}+1e-12);
    fprintf(fid,"printf 'city,year,activation\\n' > 'activation_%d.csv';\nprintf {j in city,t in year} '%%d,%%d,%%.17g\\n',j,t,(if j in candidate then activation[j,t] else 0) >> 'activation_%d.csv';\n",point,point);
    fprintf(fid,"printf 'city,year,chemistry,expansion,capacity,throughput\\n' > 'plant_%d.csv';\nprintf {j in city,t in year,k in chemistry} '%%d,%%d,%%d,%%.17g,%%.17g,%%.17g\\n',j,t,k,(if j in candidate then expansion[j,t,k] else 0),(if j in candidate then capacity[j,t,k] else 0),(if j in candidate then throughput[j,t,k] else 0) >> 'plant_%d.csv';\n",point,point);
    fprintf(fid,"printf 'origin,destination,year,route\\n' > 'route_%d.csv';\nprintf {i in city,j in candidate,t in year: route[i,j,t]!=0} '%%d,%%d,%%d,%%.17g\\n',i,j,t,route[i,j,t] >> 'route_%d.csv';\n",point,point);
    fprintf(fid,"printf 'COBRA_FINISHED\\n';\n");clear closer
end
end

function write_controls(d,progress,folder)
% No obsolete six-cold-solve .run alongside the authoritative native queue.
settings=struct('solver',table2struct(d.solver,'ToScalar',true), ...
    'solver_names',string(d.solver.Properties.RowNames), ...
    'mip_gap',d.parameter{'mip_gap','value'}, ...
    'endpoint_emission_allowance',d.parameter{'endpoint_emission_allowance','value'}, ...
    'progress',progress,'executor',"run_scenario(solve=true)");
fid=fopen(fullfile(folder,'execution_settings.json'),'w');assert(fid>=0);
fprintf(fid,'%s',jsonencode(settings,PrettyPrint=true));fclose(fid);
fid=fopen(fullfile(folder,'check.run'),'w');assert(fid>=0);closer=onCleanup(@()fclose(fid));
fprintf(fid,'reset;\noption presolve %d;\nmodel model.mod;\ndata model.dat;\n',d.solver{'ampl_presolve','value'});
fprintf(fid,"printf 'BOUND %%d %%d %%d %%d\\n',card(city),card(year),card(chemistry),has_expiry;\n");
for name=["outflow","PT","UT_fixed","LC","LE","initial_capacity"]
    if name=="initial_capacity"
        axes='j in city,k in chemistry';indices='j,k';
    elseif ismember(name,["LC","LE"])
        axes='i in city,j in candidate,t in year';indices='i,j,t';
    elseif name=="PT"
        axes='j in city,v in vintage,k in chemistry';indices='j,v,k';
    else
        axes='j in city,t in year,k in chemistry';indices='j,t,k';
    end
    fprintf(fid,"printf '%s %%.17g\\n',sum {%s} %s[%s];\n",name,axes,name,indices);
end
fprintf(fid,"printf 'COBRA_DATA_CHECKED\\n';\n");
end

function result=read_result(d,progress,folder)
n=height(d.city);t=numel(d.year);k=numel(d.chemistry);count=numel(progress);
summary=table(progress,nan(count,1),nan(count,1), ...
    repmat("not_run",count,1),nan(count,1), ...
    'VariableNames',{'progress','discounted_cost','emission','status','mip_gap'}, ...
    'RowNames',cellstr("point_"+string((1:count)')));
empty=struct('activation',[],'expansion',[],'capacity',[],'throughput',[],'route',[],'cost',[],'emission',[]);
result=struct('city',d.city,'year',d.year(:),'chemistry',d.chemistry(:), ...
    'window',d.scenario.window,'scenario',rmfield(d.scenario,'window'), ...
    'summary',summary,'solution',repmat(empty,count,1));
raw=readtable(fullfile(folder,'summary.csv'),'TextType','string');
if any(~isfinite(raw.point)|raw.point<1|raw.point>count|raw.point~=fix(raw.point))|| ...
        numel(unique(raw.point))~=height(raw)||any(~isfinite(raw.result_num)|raw.result_num<0)
    error('optimization:Results','Invalid or duplicate point numbers.');
end
for row=1:height(raw)
    point=raw.point(row);
    result.summary{point,{'discounted_cost','emission','mip_gap'}}=raw{row,{'discounted_cost','emission','mip_gap'}};
    result.summary.status(point)=raw.status(row);
    if raw.result_num(row)>=100,continue,end
    if ~isfinite(raw.mip_gap(row))||raw.mip_gap(row)>d.parameter{'mip_gap','value'}+1e-12
        result.summary.status(point)="gap_not_met";continue
    end
    directory=fullfile(folder,sprintf('point_%d',point));
    if ~isfolder(directory),directory=folder;end
    a=readmatrix(fullfile(directory,sprintf('activation_%d.csv',point)),'NumHeaderLines',1);
    b=readmatrix(fullfile(directory,sprintf('plant_%d.csv',point)),'NumHeaderLines',1);
    c=readmatrix(fullfile(directory,sprintf('route_%d.csv',point)),'NumHeaderLines',1);
    av=unpack(a,[n t],{1:n,d.year},true);
    solution=empty;
    solution.activation=array2table(av,'RowNames',d.city.Properties.RowNames, ...
        'VariableNames',cellstr(string(d.year(:)')));
    names=["expansion","capacity","throughput","cost","emission"];
    if size(b,2)==6,names=names(1:3);end
    for z=1:numel(names)
        solution.(names(z))=unpack(b(:,[1:3 z+3]),[n t k],{1:n,d.year,1:k},true);
    end
    if isempty(c),c=zeros(0,4);end
    solution.route=unpack(c,[n n t],{1:n,1:n,d.year},false);
    if size(b,2)==6
        [solution.cost,solution.emission]=reconstruct_accounting(d,solution);
    end
    validate_solution(d,solution,raw.discounted_cost(row),raw.emission(row));
    result.solution(point)=solution;result.summary.status(point)="solved";
end
if all(result.summary.status([1 count])=="solved")
    high=result.summary.emission(1);low=result.summary.emission(count);
    if low>high
        warning('optimization:Endpoints','Reported minimum-emission endpoint exceeds the cost endpoint; no interior points are certified.');
    else
        reference_path=fullfile(folder,'endpoint_reference.json');
        if isfile(reference_path)
            budget=jsondecode(fileread(reference_path));
            high=budget.emission_at_min_cost;low=budget.emission_cap;
        end
        emission_limit=high-progress*(high-low);
        solved=result.summary.status=="solved";
        excess=result.summary.emission(solved)-emission_limit(solved);
        if any(excess>1e-6+1e-8*abs(emission_limit(solved)))
            error('optimization:EmissionLimit','A returned point exceeds its emission limit.');
        end
    end
end
end

function x=unpack(rows,shape,axes,complete)
q=numel(shape);
if size(rows,2)~=q+1||any(~isfinite(rows),'all')
    error('optimization:Results','Malformed numeric result file.');
end
index=cell(1,q);
for j=1:q
    [found,index{j}]=ismember(rows(:,j),axes{j});
    if ~all(found),error('optimization:Results','Unknown result coordinate.');end
end
flat=sub2ind(shape,index{:});
if numel(unique(flat))~=numel(flat)||(complete&&numel(flat)~=prod(shape))
    error('optimization:Results','Missing or duplicate result coordinates.');
end
x=zeros(shape);x(flat)=rows(:,end);
end

function validate_solution(d,s,total_cost,total_emission)
% Recompute balances and all accounting independently from raw decisions.
% Tolerances validate solver output; no clipping/rounding changes saved data.
n=height(d.city);t=numel(d.year);k=numel(d.chemistry);
a=s.activation{:,:};tol=1e-5;
if any(abs(a-round(a))>tol,'all')||any(a< -tol|a>1+tol,'all')|| ...
        any(a>d.actor+tol,'all')||any(s.expansion< -tol,'all')|| ...
        any(s.route< -tol|s.route>1+tol,'all')
    error('optimization:Feasibility','Invalid activation, expansion or routing.');
end
capacity=zeros(n,t,k);throughput=capacity;cost=capacity;emission=capacity;
base=d.parameter{'base_year','value'};
capital=d.PT+d.LD+d.MT+d.IS;
for y=1:t
    alive=d.year<=d.year(y)&d.year(y)<d.year+d.life;
    stock=d.initial_capacity;
    if string(d.scenario.mode)=="greenfield"||d.year(y)>=base+1+d.life,stock(:)=0;end
    capacity(:,y,:)=reshape(stock,n,1,k)+sum(s.expansion(:,alive,:),2);
    q=reshape(d.outflow(:,y,:),n,k);
    throughput(:,y,:)=reshape(s.route(:,:,y)'*q,n,1,k);
    allocated=sum(s.route(:,:,y),2);
    expected=double(sum(q,2)>0);
    if any(abs(allocated-expected)>tol)||any(s.route(:,:,y)>a(:,y)'+tol,'all')
        error('optimization:Feasibility','Allocation or route activation violated.');
    end
    costs=reshape(stock,n,1,k).*capital(:,1,:) ...
        +sum(s.expansion(:,alive,:).*capital(:,find(alive)+1,:),2) ...
        +(d.LB(:,y,:)+d.GA(:,y,:)+d.UT_fixed(:,y,:)).*capacity(:,y,:) ...
        +(d.RM(:,y,:)+d.UT(:,y,:)-d.UT_fixed(:,y,:)+d.WD(:,y,:)+d.RD(:,y,:)).*throughput(:,y,:);
    gases=(d.PC(:,y,:)+d.UM(:,y,:)+d.WT(:,y,:)).*throughput(:,y,:);
    for z=1:k
        costs(:,1,z)=costs(:,1,z)+sum((d.LC(:,:,y)+d.price_rate*d.BT(z)).*s.route(:,:,y).*q(:,z),1)';
        gases(:,1,z)=gases(:,1,z)+sum(d.LE(:,:,y).*s.route(:,:,y).*q(:,z),1)';
    end
    cost(:,y,:)=costs;emission(:,y,:)=gases;
end
near(s.capacity,capacity,'capacity');near(s.throughput,throughput,'throughput');
near(s.cost,cost,'cost');near(s.emission,emission,'emission');
site=sum(capacity,3);processed=sum(throughput,3);
limit=d.parameter{'throughput_share_max','value'}*sum(sum(d.outflow,3),1);
if any(throughput-capacity>tol+1e-8*abs(capacity),'all')|| ...
        any(site<d.parameter{'minimum_capacity','value'}*a-tol,'all')|| ...
        any(abs(site(a<.5))>tol)||any(processed>limit+tol+1e-8*abs(limit),'all')
    error('optimization:Feasibility','Capacity, site activation or national-share limit violated.');
end
discount=ones(1,t);
if d.parameter{'discount_cost','value'}==1
    discount=(1+d.parameter{'discount_rate','value'}).^(-(d.year-base));
end
near(sum(cost.*reshape(discount,1,t,1),'all'),total_cost,'discounted total cost');
near(sum(emission,'all'),total_emission,'total emission');
end

function near(actual,expected,label)
if any(~isfinite(actual),'all')||any(~isfinite(expected),'all')|| ...
        any(abs(actual-expected)>1e-5+1e-8*abs(expected),'all')
    error('optimization:Validation','Reconstructed %s differs from the solver export.',label);
end
end

function [cost,emission]=reconstruct_accounting(d,s)
n=height(d.city);t=numel(d.year);k=numel(d.chemistry);
capacity=zeros(n,t,k);throughput=capacity;cost=capacity;emission=capacity;
base=d.parameter{'base_year','value'};
capital=d.PT+d.LD+d.MT+d.IS;
for y=1:t
    alive=d.year<=d.year(y)&d.year(y)<d.year+d.life;
    stock=d.initial_capacity;
    if string(d.scenario.mode)=="greenfield"||d.year(y)>=base+1+d.life,stock(:)=0;end
    capacity(:,y,:)=reshape(stock,n,1,k)+sum(s.expansion(:,alive,:),2);
    q=reshape(d.outflow(:,y,:),n,k);
    throughput(:,y,:)=reshape(s.route(:,:,y)'*q,n,1,k);
    costs=reshape(stock,n,1,k).*capital(:,1,:) ...
        +sum(s.expansion(:,alive,:).*capital(:,find(alive)+1,:),2) ...
        +(d.LB(:,y,:)+d.GA(:,y,:)+d.UT_fixed(:,y,:)).*capacity(:,y,:) ...
        +(d.RM(:,y,:)+d.UT(:,y,:)-d.UT_fixed(:,y,:)+d.WD(:,y,:)+d.RD(:,y,:)).*throughput(:,y,:);
    gases=(d.PC(:,y,:)+d.UM(:,y,:)+d.WT(:,y,:)).*throughput(:,y,:);
    for z=1:k
        costs(:,1,z)=costs(:,1,z)+sum((d.LC(:,:,y)+d.price_rate*d.BT(z)).*s.route(:,:,y).*q(:,z),1)';
        gases(:,1,z)=gases(:,1,z)+sum(d.LE(:,:,y).*s.route(:,:,y).*q(:,z),1)';
    end
    cost(:,y,:)=costs;emission(:,y,:)=gases;
end
end


function [raw,timing]=correct_endpoint(d,progress,parent,ampl,solver,original,cap)
% Reuse only this scenario's fully validated emission-minimizing incumbent.
count=numel(progress);folder=fullfile(parent,'endpoint_correction');mkdir(folder);
copyfile(fullfile(parent,'model.mod'),fullfile(folder,'model.mod'));
copyfile(fullfile(parent,'model.dat'),fullfile(folder,'model.dat'));
cert=emission_certificate(d,folder,cap,ampl,solver);
assert(abs(cert.primal-original.summary.emission(end))<max(.1,1e-8*cert.primal));
d.endpoint_correction=true;
model=fileread(fullfile(folder,'model.mod'));
declaration=sprintf('param residual_coef {city,candidate,year} >= 0 default 0;\nparam residual_penalty {candidate,year} >= 0 default 0;\n');
model=replace(model,'var route {city,candidate,year} >= 0 <= 1;', ...
    declaration+"var route {i in city,j in candidate,t in year} >= 0 <= (if residual_coef[i,j,t]>0 then min(1,1/residual_coef[i,j,t]) else 1);");
fid=fopen(fullfile(folder,'model.mod'),'w');fprintf(fid,'%s',model);
fprintf(fid,'\nvar residual_slack {j in candidate,t in year} >= 0;\n');
fprintf(fid,'subject to ResidualShare {j in candidate,t in year}: residual_slack[j,t]+sum{k in chemistry}throughput[j,t,k]=throughput_share_max*sum{i in city,k in chemistry}outflow[i,t,k];\n');
fprintf(fid,'subject to ResidualBudget: sum{i in city,j in candidate,t in year}residual_coef[i,j,t]*route[i,j,t]+sum{j in candidate,t in year}residual_penalty[j,t]*residual_slack[j,t]<=1;\n');fclose(fid);
fid=fopen(fullfile(folder,'seed.run'),'w');assert(fid>=0);
for key=["activation","expansion","route"]
    v=original.solution(count).(key);if istable(v),v=v{:,:};end
    linear=find(v~=0);
    if isempty(linear),continue,end
    if key=="activation"
        [i,y]=ind2sub(size(v),linear);fprintf(fid,'let activation[%d,%d] := %.17g;\n',[i,d.year(y),v(linear)]');
    elseif key=="expansion"
        [i,y,k]=ind2sub(size(v),linear);fprintf(fid,'let expansion[%d,%d,%d] := %.17g;\n',[i,d.year(y),k,v(linear)]');
    else
        [i,j,y]=ind2sub(size(v),linear);fprintf(fid,'let route[%d,%d,%d] := %.17g;\n',[i,j,d.year(y),v(linear)]');
    end
end
fprintf(fid,'let {j in candidate,t in year} residual_slack[j,t] := max(0,throughput_share_max*sum{i in city,k in chemistry}outflow[i,t,k]-sum{i in city,k in chemistry}outflow[i,t,k]*route[i,j,t]);\n');fclose(fid);

[raw,timing]=run_points(d,progress,folder,count,ampl,solver,original.summary.emission(1),cap);
assert(raw.result_num<100 && raw.mip_gap<=d.parameter{'mip_gap','value'}+1e-12);
fid=fopen(fullfile(folder,'summary.csv'),'w');assert(fid>=0);
fprintf(fid,'point,status,result_num,discounted_cost,emission,mip_gap\n');
fprintf(fid,'%d,%s,%d,%.17g,%.17g,%.17g\n',raw.point,raw.status,raw.result_num,raw.discounted_cost,raw.emission,raw.mip_gap);fclose(fid);
corrected=read_result(d,progress,folder);
assert(corrected.summary.status(count)=="solved");
assert(raw.emission<=cap+1e-6+1e-8*abs(cap));
assert(raw.discounted_cost<=original.summary.discounted_cost(end)+1e-5+1e-8*abs(original.summary.discounted_cost(end)));
archive=fullfile(parent,'minimum_emission_reference');mkdir(archive);
movefile(fullfile(parent,sprintf('point_%d',count)),fullfile(archive,sprintf('point_%d',count)));
copyfile(fullfile(folder,sprintf('point_%d',count)),fullfile(parent,sprintf('point_%d',count)));
end

function cert=emission_certificate(d,folder,cap,ampl,solver)
% Exact routing projection: capacity can be freely added, no capital emissions.
% Equivalent dual residual identity, inspired by the local preview-beta audit.
n=height(d.city);J=find(d.actor);Y=d.year;t=numel(Y);
mass=sum(d.outflow,3);ef=zeros(n,numel(J),t);
for z=1:t
    q=reshape(d.outflow(:,z,:),n,6);
    unit=reshape(d.PC(J,z,:)+d.UM(J,z,:)+d.WT(J,z,:),numel(J),6);
    ef(:,:,z)=q*unit'+d.LE(:,J,z).*sum(q,2);
end
lp=fullfile(folder,'certificate');mkdir(lp);
fid=fopen(fullfile(lp,'projection.mod'),'w');assert(fid>=0);
fprintf(fid,['set I; set J; set T; param mass{I,T}>=0; param ef{I,J,T}; param share;\n' ...
    'var flow{I,J,T}>=0; minimize E:sum{i in I,j in J,t in T}ef[i,j,t]*flow[i,j,t];\n' ...
    'subject to Balance{i in I,t in T}:sum{j in J}flow[i,j,t]=(if mass[i,t]>0 then 1 else 0);\n' ...
    'subject to Share{j in J,t in T}:sum{i in I}mass[i,t]*flow[i,j,t]<=share*sum{i in I}mass[i,t];\n']);fclose(fid);
fid=fopen(fullfile(lp,'projection.dat'),'w');assert(fid>=0);
fprintf(fid,'set I :=');fprintf(fid,' %d',1:n);fprintf(fid,';\nset J :=');fprintf(fid,' %d',J);
fprintf(fid,';\nset T :=');fprintf(fid,' %d',Y);fprintf(fid,';\nparam share := %.17g;\n',d.parameter{'throughput_share_max','value'});
fprintf(fid,'param mass :=\n');
for z=1:t,fprintf(fid,'%d %d %.17g\n',[(1:n);repmat(Y(z),1,n);mass(:,z)']);end
fprintf(fid,';\nparam ef :=\n');[ii,jj]=ndgrid(1:n,J);
for z=1:t,v=ef(:,:,z);fprintf(fid,'%d %d %d %.17g\n',[ii(:),jj(:),repmat(Y(z),numel(ii),1),v(:)]');end
fprintf(fid,';\n');fclose(fid);
fid=fopen(fullfile(lp,'solve.run'),'w');assert(fid>=0);
fprintf(fid,"reset; option presolve %d; option solver '%s';\n",d.solver{'ampl_presolve','value'},replace(solver,"\","/"));
fprintf(fid,"option gurobi_options 'tech:threads=%d alg:method=%d alg:feastol=1e-8 alg:start=0 alg:basis=0 tech:timing=2';\n",d.solver{'threads','value'},d.solver{'projection_method','value'});
fprintf(fid,"model projection.mod; data projection.dat; solve;\nif solve_result_num>=100 then {exit 1;}\n");
fprintf(fid,"printf 'emission\\n%%.17g\\n',E.val > 'objective.csv';\nprintf 'j,t,dual\\n' > 'duals.csv';\nprintf {j in J,t in T} '%%d,%%d,%%.17g\\n',j,t,Share[j,t].dual >> 'duals.csv';\n");
fprintf(fid,"printf 'i,j,t,flow\\n' > 'flow.csv';\nprintf{i in I,j in J,t in T:flow[i,j,t]!=0} '%%d,%%d,%%d,%%.17g\\n',i,j,t,flow[i,j,t] >> 'flow.csv';\n");fclose(fid);
old=pwd;restore=onCleanup(@()cd(old));cd(lp);clock=tic;
status=system(char('"'+ampl+'" solve.run > ampl.log 2>&1'));seconds=toc(clock);clear restore
assert(status==0,'Routing LP did not complete.');
rows=readmatrix(fullfile(lp,'duals.csv'),'NumHeaderLines',1);penalty=zeros(n,t);
[ok,z]=ismember(rows(:,2),Y);assert(all(ok));penalty(sub2ind([n t],rows(:,1),z))=max(0,-rows(:,3));
potential=zeros(n,t);reduced=zeros(size(ef));dual=0;
for z=1:t
    adjusted=ef(:,:,z)+mass(:,z)*penalty(J,z)';
    potential(:,z)=min(adjusted,[],2)-1e-6;
    reduced(:,:,z)=adjusted-potential(:,z);
    dual=dual+sum(potential(:,z).*double(mass(:,z)>0)) ...
        -sum(penalty(J,z))*d.parameter{'throughput_share_max','value'}*sum(mass(:,z));
end
assert(all(reduced>=0,'all'));budget=cap-dual;assert(budget>0);
rows=readmatrix(fullfile(lp,'flow.csv'),'NumHeaderLines',1);flow=zeros(size(ef));
[ok,j]=ismember(rows(:,2),J);assert(all(ok));[ok,z]=ismember(rows(:,3),Y);assert(all(ok));
flow(sub2ind(size(flow),rows(:,1),j,z))=rows(:,4);
assert(max(abs(sum(flow,2)-reshape(double(mass>0),n,1,t)),[],'all')<1e-7);
slack=zeros(numel(J),t);
for z=1:t,slack(:,z)=d.parameter{'throughput_share_max','value'}*sum(mass(:,z))-flow(:,:,z)'*mass(:,z);end
assert(min(slack,[],'all')>=-1e-4);
primal=sum(ef.*flow,'all');identity=dual+sum(reduced.*flow,'all')+sum(penalty(J,:).*slack,'all');
reported=readmatrix(fullfile(lp,'objective.csv'),'NumHeaderLines',1);
assert(abs(primal-reported)<1e-5+1e-10*abs(primal));
assert(abs(identity-primal)<1e-5&&dual<=primal+1e-6&&primal-dual<.1);
cert=struct('dual_bound',dual,'primal',primal,'budget',budget,'seconds',seconds, ...
    'primal_dual_gap',primal-dual,'identity_error',identity-primal);
save(fullfile(folder,'certificate.mat'),'cert','-v7.3');
fid=fopen(fullfile(folder,'residual.dat'),'w');assert(fid>=0);
fprintf(fid,'param residual_coef :=\n');
for z=1:t,v=reduced(:,:,z)/budget;fprintf(fid,'%d %d %d %.17g\n',[ii(:),jj(:),repmat(Y(z),numel(ii),1),v(:)]');end
fprintf(fid,';\nparam residual_penalty :=\n');
for z=1:t,fprintf(fid,'%d %d %.17g\n',[J,repmat(Y(z),numel(J),1),penalty(J,z)/budget]');end
fprintf(fid,';\n');fclose(fid);
fprintf('Projection certificate: %.17g s, emission %.17g, dual gap %.17g t.\n',seconds,primal,primal-dual);
end
