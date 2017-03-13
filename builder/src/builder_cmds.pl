:- module(_, [], [fsyntax, hiord, assertions, regtypes, isomodes]).

:- doc(title,  "Builder Commands").
:- doc(author, "Jose F. Morales").

% ===========================================================================
:- doc(section, "High-level builder interface").
% TODO: move to separate module?

% :- use_module(ciaobld(builder_cmds),
% 	[builder_cleanup/0,
% 	 builder_cmd_nobndl/1,
% 	 builder_cmd_on_set/2,
% 	 set_default_recursive/1,
% 	 'cmd.needs_update_builder'/1,
% 	 'cmd.needs_rescan'/1]).
:- use_module(ciaobld(builder_targets)).
:- use_module(ciaobld(bundle_fetch), [bundle_fetch_cleanup/0]).
:- use_module(ciaobld(builder_flags),
	[set_builder_flag/2, cleanup_builder_flags/0]).
:- use_module(ciaobld(bundle_configure), [check_builder_update/0]).

:- export(builder_run/2).
builder_run(Cmd, Opts) :-
	cleanup, % TODO: repeat just in case...
	set_opts(Opts),
	run_cmd(Cmd),
	cleanup.

cleanup :-
	builder_cleanup,
	bundle_fetch_cleanup, % (may be modified by resolve_targets/2)
	cleanup_builder_flags.

set_opts([]).
set_opts([Opt|Opts]) :- set_opt(Opt), set_opts(Opts).

% TODO: ad-hoc, it does not take command into account
set_opt(opt(interactive)) :- !,
	set_builder_flag(interactive_config, true).
set_opt(opt(docs)) :- !,
	set_builder_flag(grade_docs, true).
set_opt(opt(bin)) :- !,
	set_builder_flag(grade_bin, true).
%set_opt(opt(norec)) :- !,
%	set_builder_flag(recursive, false).
set_opt(opt(r)) :- !,
	set_builder_flag(recursive, same_workspace).
set_opt(opt(x)) :- !,
	set_builder_flag(recursive, all_workspaces).
set_opt(opt(Name, Value)) :- !,
	set_builder_flag(Name, Value).
set_opt(Opt) :-
	throw(unknown_opt(Opt)).

run_cmd(cmd_on_set(Cmd, Targets0)) :-
	% Add a default target (if none is given)
	( Targets0 = [] -> % guess some
	    Targets = ['.']
	; Targets = Targets0
	),
	%
	( 'cmd.needs_update_builder'(Cmd) ->
	    check_builder_update
	; true
	),
	( 'cmd.needs_rescan'(Cmd) ->
	    rescan_targets(Targets)
	; true
	),
	resolve_targets(Targets, Targets2),
	set_default_recursive(Targets2),
	builder_cmd_on_set(Cmd, Targets2).
run_cmd(cmd(Cmd)) :-
	builder_cmd_nobndl(Cmd).

% ===========================================================================
:- doc(section, "Hooks for definition of a command").

% NOTE:
%   A command must define at least 'cmd.grade'/2 or 'cmd.do'/2.
%
%   If 'cmd.do'/2 is not defined, then we use the definitions at
%   .hook.pl files or execute the default actions on the primitive targets.

:- discontiguous('cmd.comment'/2). % comment for command
%
:- discontiguous('cmd.grade'/2). % grade, needed when when 'cmd.do'/2 is not defined
%
:- discontiguous('cmd.only_global_instype'/1). % disable if \+instype(global)
% TODO: can it be simpler to express the negation instead?
:- export('cmd.needs_update_builder'/1).
:- discontiguous('cmd.needs_update_builder'/1). % needs an up-to-date builder
:- export('cmd.needs_rescan'/1).
:- discontiguous('cmd.needs_rescan'/1). % needs rescanned bundles
:- discontiguous('cmd.needs_config'/1). % needs a configuration
%
:- discontiguous('cmd.recursive'/2). % recursive on dependencies
                                     %  - forward: dependencies first
                                     %  - backward: dependencies later
                                     %  - none (or undeclared): do not process deps
%
:- discontiguous('cmd.do_before.decl'/1). % has 'cmd.do_before'/2
:- discontiguous('cmd.do_before'/2). % do_before command
:- discontiguous('cmd.no_manifest_load'/1). % manifest does not need to be loaded (only for some 'cmd.do'/2)
:- discontiguous('cmd.do.decl'/1). % has 'cmd.do'/2
:- discontiguous('cmd.do'/2). % do command
:- discontiguous('cmd.do_after.decl'/1). % has 'cmd.do_after'/2
:- discontiguous('cmd.do_after'/2). % do_after command

% ===========================================================================
:- doc(section, "Builder commands without bundle targets").

:- export(builder_cmd_nobndl/1).
:- discontiguous(builder_cmd_nobndl/1).

% ---------------------------------------------------------------------------
% List bundles

:- use_module(library(format), [format/2]).
:- use_module(library(sort), [sort/2]).
:- use_module(engine(internals), ['$bundle_id'/1]).

builder_cmd_nobndl(list) :- !,
	list_bundles.

:- export(list_bundles/0).
:- pred list_bundles # "List all registered bundles".
list_bundles :-
	( % (failure-driven loop)
	  member(Bundle, ~sort(~findall(X, '$bundle_id'(X)))),
	    format("~w\n", [Bundle]),
	    fail
	; true
	).

% ---------------------------------------------------------------------------
% Clean of a directory tree, recursively

builder_cmd_nobndl(clean_tree(Dir)) :- !,
	clean_tree(Dir).

% ===========================================================================
:- doc(section, "Execute a builder command (with targets)").

:- use_module(library(aggregates), [findall/3]).
:- use_module(library(lists), [reverse/2]).

:- use_module(ciaobld(messages_aux), [cmd_message/3, dmc_message/3]).
:- use_module(ciaobld(install_aux), [instype/1]).
:- use_module(ciaobld(manifest_compiler), [
    ensure_load_manifest/1,
    manifest_call/2,
    manifest_current_predicate/2,
    target_is_bundle/1,
    split_target/3,
    compose_target/3
]).

% Status of each (Cmd,Target):
%  - (fail): unknown
%  - working: started, not completed
%  - done: done
:- data builder_cmd_status/3.

% grade_ready(Grade): Grade is ready (all its required tools are compiled, etc.)
:- data grade_ready/1.

set_cmd_status(Cmd, Target, Status) :-
	retractall_fact(builder_cmd_status(Cmd, Target, _)),
	assertz_fact(builder_cmd_status(Cmd, Target, Status)).

get_cmd_status(Cmd, Target, Status) :-
	builder_cmd_status(Cmd, Target, Status0), !,
	Status = Status0.

:- export(builder_cleanup/0).
:- pred builder_cleanup # "Cleanup the builder state".

builder_cleanup :-
	retractall_fact(grade_ready(_)),
	retractall_fact(builder_cmd_status(_, _, _)).

:- export(builder_cmd_on_set/2).
% TODO: Execute in parallel?
builder_cmd_on_set(Cmd, Targets) :-
	( % (failure-driven loop)
	  member(Target, Targets),
	    builder_cmd(Cmd, Target),
	    fail
	; true
	).

:- export(builder_cmd/2).
:- pred builder_cmd(Cmd, Target) # "Perform command @var{Cmd} on
   target @var{Target}".

builder_cmd(Cmd, Target) :-
	get_cmd_status(Cmd, Target, Status),
	!,
	( Status = working ->
	    % TODO: report loop? (no error for maybe_update_ciaobase and maybe_update_lpdoc)
	    true
	; Status = done ->
	    true
	; throw(unknown_cmd_status(Status))
	).
builder_cmd(Cmd, Target) :-
	set_cmd_status(Cmd, Target, working),
	builder_cmd_(Cmd, Target),
	set_cmd_status(Cmd, Target, done).

builder_cmd_(Cmd, _Target) :-
	cmd_grade(Cmd, Grade),
	\+ enabled_grade(Grade),
	!,
	% Skip this command (grade is not enabled)
	true.
builder_cmd_(Cmd, _Target) :-
	'cmd.only_global_instype'(Cmd), \+ ~instype = global, !,
	% Skip this command (needs global installation)
	true.
builder_cmd_(Cmd, Target) :-
	% Prepare special targets for grades (e.g., ciaoc, lpdoc)
	( 'cmd.needs_update_builder'(Cmd) ->
	    cmd_grade(Cmd, Grade),
	    ensure_grade_ready(Grade, Target)
	; true
	),
	% Check that config exists if needed (does a plain configuration)
	( target_is_workspace(Target) -> true % (not for workspaces)
	; 'cmd.needs_config'(Cmd) ->
	    ensure_configured(Target)
	; true
	),
	% Ensure that metasrc is loaded if needed
	( target_is_workspace(Target) -> true % (not for workspaces)
	; 'cmd.do.decl'(Cmd), 'cmd.no_manifest_load'(Cmd) -> % do not need metasrc to execute
	    true
	; ensure_load_manifest(Target) % TODO: increment reference counting?
	),
	% Command on dependant targets (forward, e.g., install)
	( 'cmd.recursive'(Cmd, forward) -> builder_cmd_on_set(Cmd, ~target_deps(Target)) ; true ),
	% Pre-processing before command
	( 'cmd.do_before.decl'(Cmd) -> 'cmd.do_before'(Cmd, Target) ; true ),
	% Action for this command
	cmd_action(Cmd, Target, Do, Pending),
	% Execute command (and show begin and end comments if needed)
	( target_is_workspace(Target) -> Comment = [] % (not for workspaces)
	; cmd_comment(Cmd, Do, Pending, Comment)
	),
	( Comment = [Before|_] -> cmd_message(Target, Before, []) ; true ),
	( cmd_do(Do) -> true
	; throw(error(failed(Cmd,Target), builder_cmd/2))
	),
	builder_cmd_on_set(Cmd, ~items_to_targets(Pending)), % NOTE: must be called before do_after!
	( Comment = [_, After] -> dmc_message(Target, After, []) ; true ),
	% Post-processing after command
	( 'cmd.do_after.decl'(Cmd) -> 'cmd.do_after'(Cmd, Target) ; true ),
	% Backward commands on dependencies
	( 'cmd.recursive'(Cmd, backward) -> builder_cmd_on_set(Cmd, ~reverse(~target_deps(Target))) ; true ),
	% Reversing the 'initial' setup if needed
	( Cmd = clean, root_target(Target) -> % TODO: do reference counting, treat as 'initial' dependency
	    do_clean_root_target(Target)
	; true
	).

% Obtain action Do for the command and pending nested Pending when needed
cmd_action(Cmd, Target, Do, Pending) :-
	( 'cmd.do.decl'(Cmd) -> % defined here
	    Do = do(Cmd, Target),
	    Pending = []
	; target_is_workspace(Target) -> % a workspace
	    Do = nothing, % (all work is done through dependant targets)
	    Pending = []
	; manifest_current_predicate(Target, Cmd) -> % declared in a hook
	    Do = hook(Target, Cmd),
	    Pending = []
	; % use grade defaults
          cmd_grade(Cmd, Grade),
	  grade_defs(Grade, Target, Defs),
	  ( 'cmd.recursive'(Cmd, backward) -> % TODO: Use another prop?
	      Defs2 = ~reverse(Defs)
	  ; Defs2 = Defs
	  ),
	  % TODO: use another prop for recursion in nested?
	  split_target(Target, Bundle, _Part),
	  ( 'cmd.recursive'(Cmd, forward) ->
	      Pending = ~get_nested_items(Target, Bundle)
	  ; 'cmd.recursive'(Cmd, backward) ->
	      Pending = ~reverse(~get_nested_items(Target, Bundle))
	  ; Pending = []
	  ),
	  Do = defs(Cmd, Defs2, Grade, Bundle)
	).

% Grade for the command
cmd_grade(Cmd, Grade) :-
	( 'cmd.grade'(Cmd, Grade) -> true
	; Grade = none % the 'none' grade
	).

% Comment for the given action Do
cmd_comment(Cmd, Do, Pending, Comment) :-
	( Do = defs(_,[],_,_), Pending = [] -> Comment = []
	; Do = defs(_,[],_,_), Pending = [item_alias(_)] -> Comment = []
	; 'cmd.comment'(Cmd, Comment0) -> Comment = Comment0
	; Comment = []
	).

cmd_do(nothing). % TODO: plug here commands for workspaces?
cmd_do(do(Cmd, Target)) :- 'cmd.do'(Cmd, Target).
cmd_do(hook(Target, Cmd)) :- manifest_call(Target, Cmd).
cmd_do(defs(Cmd, Defs2, Grade, Bundle)) :- defs_do(Defs2, Grade, Bundle, Cmd).

% (item_nested(_);item_alias(_))
% (Bundle is the top context)
get_nested_items(Target, Bundle, Defs) :-
	findall(Def, get_nested_item(Target, Bundle, Def), Defs).

get_nested_item(Target, Bundle, Def) :- !,
	( Def = item_nested(Y), manifest_call(Target, item_nested(X))
	; Def = item_alias(Y), manifest_call(Target, item_alias(X))
	),
	compose_target(Bundle, X, Y).

items_to_targets([], []).
items_to_targets([X|Xs], [Y|Ys]) :-
	( X = item_nested(Y) -> true
	; X = item_alias(Y) -> true
	; fail
	),
	items_to_targets(Xs, Ys).

target_deps(Target, Deps) :-
	findall(P, target_dep(Target, P), Deps).

% Dependencies of a bundle or bundles under a workspace
target_dep(Target, Dep) :-
	target_is_workspace(Target), !,
	workspace_bundles(Target, Dep).
target_dep(Target, Dep) :-
	split_target(Target, Bundle, Part),
	( Part = '' -> bundle_dep(Bundle, Dep)
	; manifest_call(Target, item_dep(X2)),
	  compose_target(Bundle, X2, Dep)
	).

% ---------------------------------------------------------------------------
% Kinds of targets (workspaces, bundles, or parts of a bundle)

% (bundle or bundle part)
check_no_workspace(Target) :-
	( \+ target_is_workspace(Target) -> true
	; throw(error_msg("Operation not allowed on workspaces.", []))
	).

% (workspace or bundle)
check_no_part(Target) :-
	( target_is_bundle(Target) -> true
	; throw(error_msg("Operation not allowed on bundle parts.", []))
	).

:- export(root_target/1).
:- pred root_target/1 # "Target for the whole CIAOROOT workspace.".
root_target(Target) :- ciao_root(Target).

:- use_module(engine(internals), [ciao_root/1, ciao_path/1]).

% The target is a (known) workspace
target_is_workspace(Target) :- ciao_path(Target).
target_is_workspace(Target) :- ciao_root(Target).

% ---------------------------------------------------------------------------
% Dependencies of a bundle

:- use_module(engine(internals), ['$bundle_srcdir'/2]). % TODO: Do not use bundle_srcdir here? add manifest_srcdir for build-time?
:- use_module(library(pathnames), [path_get_relative/3]).
:- use_module(ciaobld(builder_flags), [get_builder_flag/2]).

% ParentBundle depends on Bundle (limited by the value of the
% 'recursive' builder flag)
bundle_dep(ParentBundle, Bundle) :-
	bundle_dep_(ParentBundle, Bundle),
	( get_builder_flag(recursive, all_workspaces) -> true
	; get_builder_flag(recursive, same_workspace) ->
	    bundle_share_workspace(ParentBundle, Bundle)
	; fail
	).

bundle_dep_(Bundle, Dep) :-
	manifest_call(Bundle, dep(Dep, _)).

:- use_module(library(bundle/bundle_paths), [bundle_path/4]).

:- export(bundle_share_workspace/2).
% Two bundles are in the same workspace if they have the same builddir
bundle_share_workspace(BundleA, BundleB) :-
	A = ~bundle_path(BundleA, builddir, '.'),
	B = ~bundle_path(BundleB, builddir, '.'),
	A == B.

% ---------------------------------------------------------------------------
% Bundles in a workspace
%
% For covenience we fix some particular order for system bundles
% (bundles at ciao_root/1). See fix_order_sys_bundle/1.
%
% NOTE: order really does not matter since bundle dependencies are
%   taken into acoount, but it is clear for some user operations like
%   configuring bundles.

workspace_bundles(Wksp, Bundle) :- ciao_root(Wksp), !,
	sys_bundles(Bundle).
workspace_bundles(Wksp, Bundle) :-
	'$bundle_id'(Bundle),
	bundle_in_workspace(Wksp, Bundle).

bundle_in_workspace(Wksp, Bundle) :-
	% SrcDir is relative to Wksp
	'$bundle_srcdir'(Bundle, SrcDir),
	path_get_relative(Wksp, SrcDir, _).

sys_bundles(Bundle) :- fix_order_sys_bundle(Bundle), '$bundle_id'(Bundle).
sys_bundles(Bundle) :-
	ciao_root(CiaoRoot),
	'$bundle_id'(Bundle),
	\+ fix_order_sys_bundle(Bundle),
	bundle_in_workspace(CiaoRoot, Bundle).

fix_order_sys_bundle(builder).
fix_order_sys_bundle(core).

is_sys_bundle(Bundle) :-
	ciao_root(CiaoRoot),
	'$bundle_id'(Bundle),
	bundle_in_workspace(CiaoRoot, Bundle).

% ---------------------------------------------------------------------------
% Ensures that we have a configuration for the given target

:- use_module(ciaobld(bundle_configure), [bundle_has_config/1]).

ensure_configured(Target) :-
	split_target(Target, Bundle, _Part),
	( \+ bundle_has_config(Bundle) ->
	    % Configure with default values
	    builder_cmd(configure([]), Bundle)
	    % throw(error_msg("Cannot do '~w' on bundle '~w' without a configuration. Please run 'configure' before.", [Cmd, Bundle]))
	; true
	).

% ---------------------------------------------------------------------------
% Set the default recursive flag (it depends on targets)

:- use_module(ciaobld(builder_flags), [set_builder_flag/2]).

:- export(set_default_recursive/1).
set_default_recursive(Targets) :-
	( member(X, Targets), root_target(X) ->
	    % For root_target, enable recursive by default
	    % TODO: use same_workspace for other workspaces?
	    set_builder_flag(recursive, all_workspaces)
	; true
	).

% ===========================================================================
:- doc(section, "Grades").

% ---------------------------------------------------------------------------
% Selection of grades (bin, docs, etc.)

:- use_module(ciaobld(config_common), [with_docs/1]).

enabled_grade(none) :- !.
enabled_grade(custom) :- !. % TODO: better way?
enabled_grade(custom_bin) :- !. % TODO: better way?
enabled_grade(custom_docs) :- !. % TODO: better way?
enabled_grade(test) :- !. % TODO: implement
enabled_grade(bench) :- !. % TODO: implement
%
enabled_grade(bin) :- !,
	( default_grades -> true
	; get_builder_flag(grade_bin, true)
	).
enabled_grade(docs) :- !,
	with_docs(yes),
	( default_grades -> true
	; get_builder_flag(grade_docs, true)
	).

default_grades :-
	% none specified
	\+ get_builder_flag(grade_bin, _),
	\+ get_builder_flag(grade_docs, _).

grade_requires(bin, 'core.ciaobase').
grade_requires(docs, 'lpdoc').

% ---------------------------------------------------------------------------
% Prepare requirements for grades (e.g., ciaoc, lpdoc)
%
% This is required to insert the implicit dependencies between a
% bundle and some specific tool available in another bundle.
%
% NOTE: If 'recursive' flag does not allow the bundle recursion to
%   reach a system bundle, we assume that the grade is prepared.

% TODO: very similar to load_compilation_module!

ensure_grade_ready(Grade, _Target) :-
	grade_ready(Grade), !.
ensure_grade_ready(Grade, Target) :-
	( \+ reach_sys_bundle(Target) ->
	    % (assume grade is prepared)
	    % TODO: show error if not available?
	    true
	; prepare_grade(Grade, Target)
	),
	assertz_fact(grade_ready(Grade)).

% Prepare the grade
prepare_grade(Grade, ParentTarget) :-
	( % (failure-driven loop)
	  grade_requires(Grade, ReqTarget),
	    \+ ParentTarget = ReqTarget,
	    builder_cmd(build_bin, ReqTarget),
	    fail
	; true
	).

% System bundles are reachable (given 'recursive' flag) from Bundle:
%
%  - either we have unlimited bundle recursion
%  - or Bundle is system bundle
%
% This is used for grade requirements and it does not consider bundle
% dependencies.

reach_sys_bundle(_Target) :-
	get_builder_flag(recursive, all_workspaces), !.
reach_sys_bundle(Target) :-
	get_builder_flag(recursive, same_workspace),
	( root_target(Target) -> true % contain system bundles
	; target_is_workspace(Target) -> fail % do not contain system bundle
	; split_target(Target, Bundle, _Part),
	  is_sys_bundle(Bundle) % is a system bundle
	).

% ---------------------------------------------------------------------------

:- use_module(ciaobld(builder_prim), [
  bintgt/1, bintgt_do/3,
  docstgt/1, docstgt_do/3
]).

% Primitive targets for this grade (when no hook is provided)
grade_defs(custom, Target, _Defs) :- !, % TODO: better idea?
	% Hooks are mandatory for this grade
	throw(error(bundlehook_undefined(Target,custom_run/2), builder_cmd/2)).
grade_defs(Grade, Target, Defs) :-
	findall(Def, grade_defs_(Grade, Target, Def), Defs).

grade_defs_(custom_bin, _Target, _Def) :- !, fail. % TODO: for prepare_build_bin
grade_defs_(custom_docs, _Target, _Def) :- !, fail. % TODO: for prepare_build_docs
grade_defs_(test, _Target, _Def) :- !, fail. % TODO: FIX
grade_defs_(bench, _Target, _Def) :- !, fail. % TODO: FIX
grade_defs_(bin, Target, Def) :- !,
	bintgt(Def), % (enumerate primitive targets)
	manifest_call(Target, Def).
grade_defs_(docs, Target, Def) :- !,
	docstgt(Def), % (enumerate primitive targets)
	manifest_call(Target, Def).

% (Bundle is the top context)
defs_do([], _Grade, _Bundle, _Cmd).
defs_do([X|Xs], Grade, Bundle, Cmd) :-
	( Grade = docs -> docstgt_do(X, Bundle, Cmd)
	; Grade = bin -> bintgt_do(X, Bundle, Cmd)
	; throw(unknown_grade_defs_do(Grade))
	),
	defs_do(Xs, Grade, Bundle, Cmd).

% ===========================================================================
:- doc(section, "Definition of builder commands").

% ---------------------------------------------------------------------------

% Do nothing (it just needs rescan -- done by ciao_builder.pl)
'cmd.needs_update_builder'(rescan_bundles).
'cmd.needs_rescan'(rescan_bundles).
'cmd.no_manifest_load'(rescan_bundles).
'cmd.do.decl'(rescan_bundles).
'cmd.do'(rescan_bundles, _Target) :- !.

% ---------------------------------------------------------------------------
% fetch, rm

:- use_module(ciaobld(bundle_fetch), [bundle_fetch/2, bundle_rm/1]).

% Fetch the given bundle
'cmd.needs_update_builder'(fetch).
'cmd.needs_rescan'(fetch).
'cmd.no_manifest_load'(fetch).
'cmd.do.decl'(fetch).
'cmd.do'(fetch, Target) :-
	check_no_workspace(Target),
	check_no_part(Target),
	bundle_fetch(Target, _Fetched).

% Remove a downloaded bundle
'cmd.no_manifest_load'(rm).
'cmd.do.decl'(rm).
'cmd.do'(rm, Target) :- !,
	check_no_workspace(Target),
	check_no_part(Target),
	bundle_rm(Target).

% ---------------------------------------------------------------------------
% get (fetch+full_install)

'cmd.needs_update_builder'(get(_)).
'cmd.needs_rescan'(get(_)).
'cmd.no_manifest_load'(get(_)).
'cmd.do.decl'(get(_)).
'cmd.do'(get(Flags), Target) :- !,
	bundle_fetch(Target, Fetched0), % builder_cmd(fetch, Target),
	% TODO: reorder looking at dependencies! (indeed, this should be done automatically in cmd_on_set)
	Fetched1 = ~reverse(Fetched0),
	%
	( \+ bundle_has_config(core), % TODO: 'core' hardwired
	  is_sys_bundle(Target) ->
	    % Special case for './ciao-boot.sh get ...' when the system
	    % has not been configured/built before
	    % TODO: reimplement adding unconfigured from deps instead?
	    root_target(Tgt),
	    Fetched = [Tgt],
	    BundleSet = set(~findall(B, workspace_bundles(Tgt, B))),
	    % For root_target, fix default recursive (recursive by default)
	    set_default_recursive(Fetched) % TODO: ugly?
	; Fetched = Fetched1,
	  BundleSet = set(Fetched)
	),
	% TODO: extend BundleSet with more bundles that may be specified in flags?
	bundleset_configure(BundleSet, Flags),
	builder_cmd_on_set(build, Fetched),
	builder_cmd_on_set(install, Fetched).

% ---------------------------------------------------------------------------

'cmd.needs_update_builder'(full_install(_)).
'cmd.needs_rescan'(full_install(_)).
'cmd.no_manifest_load'(full_install(_)).
'cmd.do.decl'(full_install(_)).
'cmd.do'(full_install(Flags), Target) :- !,
	builder_cmd(configure(Flags), Target),
	builder_cmd(build, Target),
	builder_cmd(install, Target).

% ---------------------------------------------------------------------------
% Promote bootstrap compiler (dangerous!)

:- use_module(ciaobld(interactive_aux), [ask_yesno/1]).
:- use_module(ciaobld(config_common), [default_eng_def/1]).
:- use_module(ciaobld(ciaoc_aux), [promote_bootstrap/1]).
:- use_module(ciaobld(messages_aux), [normal_message/2]).

% TODO: implement promotion of other engine?
'cmd.comment'(boot_promote, ["promoting bootstrap"]).
'cmd.needs_config'(boot_promote).
'cmd.do.decl'(boot_promote).
'cmd.do'(boot_promote, Target) :- !,
	( Target = 'core.engine' ->
	    true
	; throw(error_msg("Invalid target ~w. Only 'core.engine' is supported for bootstrap promotion.", [Target]))
	),
	%
	ask_promote_bootstrap(~default_eng_def).

% TODO: Create a backup/ directory with a NODISTRIBUTE flag?
% TODO: Should it be an operation of core.ciaoc?
%
% NOTE: It only saves the static ciaoc (but it could save other
% bootstrapping data like documentation in the future).

ask_promote_bootstrap(Eng) :-
	normal_message("The current compiler, including automatically generated C code for the", []),
	normal_message("emulator will become the next bootstrap system.", []),
	%
	normal_message("(Warning: do promote unless you are completely sure)", []),
	normal_message("", []),
	( ask_yesno("Are you sure?"),
	  ask_yesno("Really?") ->
	    promote_bootstrap(Eng),
	    normal_message("Bootstrap compiler promoted", [])
	; normal_message("Promotion canceled", [])
	).

% ---------------------------------------------------------------------------
% configure

:- use_module(ciaobld(bundle_configure), [bundleset_configure/2]).

'cmd.comment'(configure(_), ["configuring", "configured"]).
'cmd.needs_update_builder'(configure(_)).
'cmd.needs_rescan'(configure(_)).
'cmd.no_manifest_load'(configure(_)).
'cmd.do.decl'(configure(_)).
'cmd.do'(configure(Flags), Target) :- !,
	check_no_part(Target),
	% Invoke configuration (pre: bundles have been scanned)
	% TODO: configure dependencies too? (same workspace? missing config?)
	( target_is_workspace(Target) ->
	    BundleSet = set(~findall(B, workspace_bundles(Target, B)))
	; BundleSet = set([Target])
	),
	bundleset_configure(BundleSet, Flags).

% ---------------------------------------------------------------------------
% configclean

% Clean the bundle configuration
% TODO: split in a configclean for each (sub)bundle or workspace
% Warning! configclean is the last cleaning step. If you clean all
%          the configuration files then many scripts will not run.
'cmd.comment'(configclean, ["cleaning [config]", "cleaned [config]"]).
'cmd.needs_config'(configclean).
'cmd.no_manifest_load'(configclean).
'cmd.do.decl'(configclean).
'cmd.do'(configclean, Target) :- !,
	( root_target(Target) -> % TODO: generalize for all workspaces
	    builddir_clean(core, config) % TODO: 'core' hardwired
	; true
	).

% ---------------------------------------------------------------------------
% list, describe, set, get flags

:- use_module(ciaobld(bundle_configure),
	[config_list_flags/1,
	 config_describe_flag/1,
	 config_set_flag/2,
	 config_get_flag/2]).

'cmd.do.decl'(config_list_flags).
'cmd.do'(config_list_flags, Target) :- !,
	check_no_workspace(Target),
	check_no_part(Target),
	config_list_flags(Target).

'cmd.do.decl'(config_describe_flag(_)).
'cmd.do'(config_describe_flag(Flag), Target) :- !,
	check_no_workspace(Target),
	check_no_part(Target),
	config_describe_flag(Flag).

'cmd.do.decl'(config_set_flag(_, _)).
'cmd.do'(config_set_flag(Flag, Value), Target) :- !,
	check_no_workspace(Target),
	check_no_part(Target),
	config_set_flag(Flag, Value).

'cmd.do.decl'(config_get_flag(_)).
'cmd.do'(config_get_flag(Flag), Target) :- !,
	check_no_workspace(Target),
	check_no_part(Target),
	display(~config_get_flag(Flag)), nl.

% ---------------------------------------------------------------------------
% build/clean

'cmd.needs_update_builder'(build).
'cmd.needs_rescan'(build).
%'cmd.needs_config'(build).
%'cmd.recursive'(build, forward). % TODO: enable?
'cmd.do.decl'(build).
'cmd.do'(build, Target) :- !,
	builder_cmd(build_bin, Target),
	builder_cmd(build_docs, Target).

% Deletes all intermediate files, but leaves configuration settings
% 'cmd.recursive'(clean, backward). % TODO: enable?
'cmd.do.decl'(clean).
'cmd.do'(clean, Target) :- !,
	builder_cmd(clean_docs, Target),
	builder_cmd(clean_bin, Target).

% ---------------------------------------------------------------------------
% build/clean (bin)

'cmd.comment'(build_bin, ["building [bin]", "built [bin]"]).
'cmd.grade'(build_bin, bin).
'cmd.needs_update_builder'(build_bin).
'cmd.needs_rescan'(build_bin).
'cmd.needs_config'(build_bin).
'cmd.recursive'(build_bin, forward).
'cmd.do_before.decl'(build_bin).
'cmd.do_before'(build_bin, Target) :- !,
	builder_cmd(prepare_build_bin, Target).

'cmd.comment'(prepare_build_bin, ["preparing build [bin]", "prepared build [bin]"]).
'cmd.grade'(prepare_build_bin, custom_bin).

:- use_module(ciaobld(builder_aux), [builddir_clean/2]).
:- use_module(ciaobld(ciaoc_aux), [clean_tree/1]).
:- use_module(library(bundle/bundle_paths), [bundle_path/3]).
:- use_module(library(pathnames), [path_concat/3]).

% Like 'clean', but keeps documentation targets.
% (This reverses the 'build_bin' and part of 'build_docs' actions)
'cmd.comment'(clean_bin, ["cleaning [bin]", "cleaned [bin]"]).
'cmd.grade'(clean_bin, bin).
'cmd.needs_config'(clean_bin).
'cmd.recursive'(clean_bin, backward).
'cmd.do_after.decl'(clean_bin).
'cmd.do_after'(clean_bin, Target) :- !,
	( target_is_workspace(Target) -> true
	; target_is_bundle(Target) ->
	    do_clean_bundle(Target) 
	; true 
	).

% TODO: make it fine grained, implement clean_bin on primtgts
do_clean_bundle(Bundle) :-
	% TODO: does not work with CIAOCACHEDIR! fix
	% TODO: clean only on lib, etc. areas (not externals/ etc.)
	% clean_tree(~bundle_path(Bundle, 'Manifest')) % TODO: only if it is a directory!
	clean_tree(~bundle_path(Bundle, '.')).

% Special case for the root build structure
% TODO: add as the 'initial' dependency for every bundle? (with reference counting)
% TODO: generalize for all workspaces
do_clean_root_target(_Target) :-
	builder_cmd(clean_bin, 'core.engine'), % TODO: clean with 'core'?
	builder_cmd(clean_bin, 'core.exec_header'), % TODO: clean with 'core'?
	% TODO: clean all builddir except configuration?
	builddir_clean(core, pbundle), % TODO: 'core' hardwired
	builddir_clean(core, bin). % TODO: 'core' hardwired

% ---------------------------------------------------------------------------
% build/clean (docs)

'cmd.comment'(build_docs, ["building [docs]", "built [docs]"]).
'cmd.grade'(build_docs, docs).
'cmd.needs_update_builder'(build_docs).
'cmd.needs_rescan'(build_docs).
'cmd.needs_config'(build_docs).
'cmd.recursive'(build_docs, forward).
'cmd.do_before.decl'(build_docs).
'cmd.do_before'(build_docs, Target) :- !,
	builder_cmd(prepare_build_docs, Target).

'cmd.comment'(prepare_build_docs, ["preparing build [docs]", "prepared build [docs]"]).
'cmd.grade'(prepare_build_docs, custom_docs).
%'cmd.needs_config'(prepare_build_docs).
%'cmd.recursive'(prepare_build_docs, forward).

% Clean documentation
'cmd.comment'(clean_docs, ["cleaning [docs]", "cleaned [docs]"]).
'cmd.grade'(clean_docs, docs).
'cmd.needs_config'(clean_docs).
'cmd.recursive'(clean_docs, backward).
'cmd.do_after.decl'(clean_docs).
'cmd.do_after'(clean_docs, Target) :- !,
	( root_target(Target) -> % TODO: generalize for all workspaces
	    builddir_clean(core, doc) % TODO: 'core' hardwired
	; true
	).

% ---------------------------------------------------------------------------
% distclean

% Like 'clean' but also removes configuration settings.
'cmd.needs_config'(distclean).
'cmd.do.decl'(distclean).
'cmd.do'(distclean, Target) :- !,
	builder_cmd(clean, Target),
	builder_cmd(configclean, Target). % Clean config (this must be the last step)
'cmd.do_after.decl'(distclean).
'cmd.do_after'(distclean, Target) :- !,
	( root_target(Target) -> % TODO: generalize for all workspaces
	    % TODO: make sure that no binary is left after 'clean' (outside builddir)
	    builddir_clean(core, bundlereg), % TODO: 'core' hardwired
	    builddir_clean(core, all) % TODO: 'core' hardwired
	; true
	).

% ---------------------------------------------------------------------------
% install/uninstall

%'cmd.needs_update_builder'(install).
'cmd.needs_rescan'(install).
%'cmd.recursive'(install, forward). % TODO: enable?
'cmd.do.decl'(install).
'cmd.do'(install, Target) :- !,
	builder_cmd(install_bin, Target),
	builder_cmd(install_docs, Target),
	builder_cmd(register, Target).

%'cmd.recursive'(uninstall, backward). % TODO: enable?
'cmd.do.decl'(uninstall).
'cmd.do'(uninstall, Target) :- !,
	builder_cmd(unregister, Target),
	builder_cmd(uninstall_docs, Target),
	builder_cmd(uninstall_bin, Target).

% ---------------------------------------------------------------------------
% install/uninstall (bin)

:- use_module(ciaobld(install_aux), [
  install_bin_dirs/1,
  uninstall_bin_dirs/1,
  install_bundlereg/1,
  uninstall_bundlereg/1
]).

'cmd.comment'(install_bin, ["installing [bin]", "installed [bin]"]).
'cmd.grade'(install_bin, bin).
'cmd.only_global_instype'(install_bin).
%'cmd.needs_update_builder'(install_bin).
'cmd.needs_rescan'(install_bin).
'cmd.recursive'(install_bin, forward).
'cmd.do_before.decl'(install_bin).
'cmd.do_before'(install_bin, Target) :- !,
	( target_is_workspace(Target) -> true
	; target_is_bundle(Target) -> install_bin_dirs(Target)
	; true
	).
'cmd.do_after.decl'(install_bin).
'cmd.do_after'(install_bin, Target) :- !,
	( target_is_workspace(Target) -> true
	; target_is_bundle(Target) -> install_bundlereg(Target) % Activate
	; true
	).

'cmd.comment'(uninstall_bin, ["uninstalling [bin]", "uninstalled [bin]"]).
'cmd.grade'(uninstall_bin, bin).
'cmd.only_global_instype'(uninstall_bin).
'cmd.recursive'(uninstall_bin, backward).
'cmd.do_before.decl'(uninstall_bin).
'cmd.do_before'(uninstall_bin, Target) :- !,
	( target_is_workspace(Target) -> true
	; target_is_bundle(Target) -> uninstall_bundlereg(Target) % Deactivate
	; true
	).
'cmd.do_after.decl'(uninstall_bin).
'cmd.do_after'(uninstall_bin, Target) :- !,
	( target_is_workspace(Target) -> true
	; target_is_bundle(Target) -> uninstall_bin_dirs(Target) % TODO: uninstall 'initial' bundle?
	; true
	).

% ---------------------------------------------------------------------------
% install/uninstall (docs)

'cmd.comment'(install_docs, ["installing [docs]", "installed [docs]"]).
'cmd.grade'(install_docs, docs).
%'cmd.needs_update_builder'(install_docs).
'cmd.needs_rescan'(install_docs).
'cmd.recursive'(install_docs, forward).

'cmd.comment'(uninstall_docs, ["uninstalling [docs]", "uninstalled [docs]"]).
'cmd.grade'(uninstall_docs, docs).
'cmd.recursive'(uninstall_docs, backward).

% ---------------------------------------------------------------------------
% register/unregister

'cmd.grade'(register, bin).
'cmd.recursive'(register, forward).

'cmd.grade'(unregister, bin).
'cmd.recursive'(unregister, backward).

% ---------------------------------------------------------------------------
% bench

'cmd.comment'(bench, ["benchmarking"]).
'cmd.grade'(bench, bench). % TODO: implement grade
'cmd.recursive'(bench, forward).

% ---------------------------------------------------------------------------
% test

'cmd.comment'(test, ["testing"]).
'cmd.grade'(test, test). % TODO: implement grade
'cmd.recursive'(test, forward).

% ---------------------------------------------------------------------------
% custom_run

'cmd.grade'(custom_run(_,_), custom).

% ---------------------------------------------------------------------------
% gen_pbundle

% Backends for pbundle (distribution) generation 
% TODO: disable 'unused module' warnings
:- use_module(ciaobld(pbundle_generator), []).
%
:- use_module(ciaobld(pbundle_gen_win32), []).
:- use_module(ciaobld(pbundle_gen_rpm), []).
:- use_module(ciaobld(pbundle_gen_mac), []).
:- use_module(ciaobld(pbundle_gen_src), []).
:- use_module(ciaobld(pbundle_gen_bin), []).

% (hooks for gen_pbundle)
:- include(ciaobld(pbundle_gen_hookdefs)).

'cmd.do.decl'(gen_pbundle).
'cmd.do'(gen_pbundle, Target) :- !,
	check_no_part(Target),
	% TODO: 'src' and 'bin' Kind have WRONG names ('nothing' implies tgz and tbz)
	( get_builder_flag(kind, Kind) ->
	    true
	; throw(bug_in_gen_pbundle)
	),
	gen_pbundle_hook(Kind, Target, []).

% ---------------------------------------------------------------------------
% gen_commit_info

:- use_module(ciaobld(bundle_hash), [bundle_gen_commit_info/1]).

% Useful to include commit info in source distributions
'cmd.do.decl'(gen_commit_info).
'cmd.do'(gen_commit_info, Target) :- !,
	check_no_workspace(Target),
	check_no_part(Target),
	bundle_gen_commit_info(Target).

% ---------------------------------------------------------------------------
% Show bundle info

:- use_module(ciaobld(manifest_compiler), [bundle_info/1]).

'cmd.do.decl'(info).
'cmd.do'(info, Target) :- !,
	check_no_workspace(Target),
	check_no_part(Target),
	bundle_info(Target).

% ---------------------------------------------------------------------------
% Show bundle documentation

:- use_module(ciaobld(lpdoc_aux), [show_doc/3]).

% TODO: add command to locate path of a given command (use cmd_path)

%	invoke_lpdoc(['--autogen_warning=yes',
%	              '--allow_markdown=no',
%	              '--syntax_highlight=no',
%	              ~atom_concat('--output_dir=', DocDir),
%		      '-t', 'ascii',
%	              SrcPath2]),

% Show bundle documentation
% TODO: allow only one manual per bundle, allow manuals on parts
'cmd.do.decl'(doc).
'cmd.do'(doc, Target) :- !,
	check_no_workspace(Target),
	check_no_part(Target),
	split_target(Target, Bundle, _Part),
	DocFormat = html, % TODO: customize?
	% just open all manuals
	( % (failure-driven loop)
	  manifest_call(Target, manual(_Base, Props)),
	    ( member(main=Path, Props) -> true
	    ; fail % ill-formed
	    ),
	    show_doc(Bundle, Path, DocFormat),
	    fail
	; true
	).
