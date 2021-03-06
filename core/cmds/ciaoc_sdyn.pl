:- module(ciaoc_sdyn, [], [assertions, datafacts]).

:- doc(title, "Standalone executables with foreign code").
:- doc(author, "Jose F. Morales").

:- doc(module, "Usage:

@begin{verbatim}
$ ciaoc_sdyn MAIN
@end{verbatim}
").

:- doc(bug, "Missing port to Windows (MinGW)").

:- use_module(engine(internals), [
    so_filename/2,
    find_pl_filename/4]).
:- use_module(engine(system_info), [get_os/1]).
:- use_module(library(aggregates), [findall/3]).
:- use_module(library(lists), [member/2, append/3]).
:- use_module(library(llists), [flatten/2]).
:- use_module(library(system),
    [file_exists/1, copy_file/3, delete_file/1, working_directory/2]).
:- use_module(library(pathnames),
    [path_split/3, path_concat/3, path_norm/2, path_is_relative/1]).
:- use_module(library(process), [process_call/3]).
:- use_module(library(format), [format/3]).
:- use_module(library(stream_utils), [open_output/2, close_output/1]).
:- use_module(engine(internals), [ciao_root/1]).

:- use_module(ciaobld(ciaoc_aux), [invoke_ciaoc/1, clean_mods/1]).

% ---------------------------------------------------------------------------

:- export(main/1).
main([MainF]) :- !,
    create_sdyn(MainF).
main(_) :-
    usage.

usage :-
    usage_text(Text),
    format(user_error,"Usage: ~s~n",[Text]).

usage_text("ciaoc_sdyn <main>

Make standalone executable for the current OS and architecture (using
ciaoc -s) and copies all the required dynamic libraries (including
dependences not in /bin or /usr/bin).
").

% NOTE: Contrary to 'ciaoc' this outputs the executable (and all
%   dylib dependencies) in the current directory.
create_sdyn(MainF) :-
    % Collect dylibs needed for MainF
    collect_dylibs(MainF),
    \+ \+ dylib(_, _), % uses at least one dylib
    !,
    % Copy dylibs (including their dependencies) and fix paths
    ( dylib(_L, SO),
      dylib_deps(SO, DepSO),
        user_so(DepSO),
        path_split(DepSO, _, SOBase),
        copy_file(DepSO, SOBase, [overwrite]),
        dylib_change_paths(SOBase),
        fail
    ; true
    ),
    % Create static exec with explicit loading of dylibs
    Stub = 'statstub.pl',
    get_mod(MainF, MainMod),
    Out = MainMod,
    create_static_stub(MainMod, Stub),
    invoke_ciaoc(['-S', '-o', Out, Stub, MainF]),
    %
    find_pl_filename(Stub, _, StubBase, _),
    clean_mods([StubBase]),
    delete_file(Stub).
create_sdyn(MainF) :- % Do a normal -S call to ciaoc
    get_mod(MainF, MainMod),
    Out = MainMod,
    invoke_ciaoc(['-S', '-o', Out, MainF]).

get_mod(F, Mod) :-
    find_pl_filename(F, _Pl, Base, _),
    path_split(Base, _, Mod).

% ---------------------------------------------------------------------------

% A user shared library (do not redistribute)
user_so(X) :-
    \+ atom_concat('/lib/', _, X),
    \+ atom_concat('/usr/lib/', _, X).

% ---------------------------------------------------------------------------
% Dynamic libraries for macOS

% The shared library or executable given by file @var{F} depends on
% the shared library @var{SO} (includes @var{F})
dylib_deps(F, DepSO) :-
    get_os('DARWIN'),
    !,
    process_call(path(otool), ['-L', F], [stdout(atmlist(Xs))]),
    Xs = [_|Xs2], % skip first
    member(X, Xs2),
    atom_codes(X, Cs),
    Cs = [0'\t|Cs0],
    append(Cs1, ".dylib ("||_, Cs0),
    append(Cs1, ".dylib", Cs2),
    atom_codes(DepSO, Cs2).
dylib_deps(F, DepSO) :-
    get_os('LINUX'),
    !,
    % TODO: See "foreign_dynlink/2: ugly trick to locate third-party libs with
    % the ./third-party/lib rpath"
    ( DepSO = F % itself (like 'otool' does)
    ; ciao_root(Dir),
      process_call(path(ldd), [F], [stdout(atmlist(Xs)), cwd(Dir)]),
      member(X, Xs),
      atom_codes(X, Cs),
      Cs = [0'\t|Cs0],
      append(_, " => "||Cs1, Cs0),
      append(Cs2, " (0x"||_, Cs1),
      \+ Cs2 = "",
      atom_codes(DepSO1, Cs2),
      ( path_is_relative(DepSO1) ->
          path_concat(Dir, DepSO1, DepSO2),
          path_norm(DepSO2, DepSO)
      ; DepSO = DepSO1
      )
    ).
dylib_deps(_F, _DepSO) :-
    get_os(OS),
    throw(error(os_not_supported(OS), dylib_deps/2)).

% Change paths for all user dynamic libraries
dylib_change_paths(F) :-
    get_os('DARWIN'),
    !,
    findall(['-change', Dep, RelDep],
            (dylib_deps(F, Dep),
             \+ F = Dep,
             user_so(Dep),
             rel_exec_path(Dep, RelDep)), Args0),
    rel_exec_path(F, RelF),
    flatten(['-id', RelF, Args0, F], Args),
    process_call(path(install_name_tool), Args, []).
dylib_change_paths(_F) :-
    get_os('LINUX'),
    !,
    true. % TODO: chrpath? patchelf?
dylib_change_paths(_F) :-
    get_os(OS),
    throw(error(os_not_supported(OS), dylib_change_paths/1)).

% From .../a/b/c to @executable_path/c (see install_name_tool man page)
rel_exec_path(X, Y) :-
    path_split(X, _, Base),
    path_concat('@executable_path', Base, Y).

% ---------------------------------------------------------------------------
% Create static stub

create_static_stub(MainMod, Stub) :-
    Sents = [
        (:- module(_, [main/1], [])),
        (:- use_module(engine(internals), [dynlink/2])),
        (:- use_module(library(system), [current_executable/1])),
        (:- use_module(library(pathnames), [path_split/3, path_concat/3])),
        (:- import(MainMod, [main/1])),
        (init_so :-
            current_executable(Exec),
            path_split(Exec, ExecDir, _),
            ( solib(M, SO),
              path_concat(ExecDir, SO, AbsSO),
              dynlink(AbsSO, M),
              fail 
            ; true
            )),
        (main(Args) :- init_so, MainMod:main(Args))
        |SOLibs],
    solib_sents(SOLibs),
    write_sents(Stub, Sents).

solib_sents(SOLibs) :-
    findall(solib(A, B), solib(A, B), SOLibs).

solib(M, SOBase) :-
    dylib(Base, SO),
    path_split(SO, _, SOBase),
    path_split(Base, _, M).

% ---------------------------------------------------------------------------

:- use_module(library(write), [portray_clause/1]).

write_sents(Stub, Sents) :-
    open_output(Stub, Out),
    ( member(X, Sents),
      portray_clause(X),
      fail
    ; true
    ),
    close_output(Out).
        
% ---------------------------------------------------------------------------
% Collect dylibs from the dependencies (transitively)

:- data dylib/2.

:- use_module(library(compiler/c_itf), [process_files_from/7, false/1]).
:- use_module(library(errhandle), [error_protect/2]).
:- use_module(library(ctrlcclean), [ctrlc_clean/1]).

collect_dylibs(F) :-
    retractall_fact(dylib(_, _)),
    error_protect(ctrlc_clean(
         process_files_from(F, asr, any, treat, false, false, true)
                  ),fail). % TODO: fail or abort?

treat(Base) :-
    so_filename(Base, SO),
    file_exists(SO),
    !,
    assertz_fact(dylib(Base, SO)).
treat(_Base).

true(_).



