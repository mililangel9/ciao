:- module(foo, [main/0], [hiord, datafacts]).

:- use_module(library(concurrency)).
:- use_module(library(system)).
:- use_module(engine(io_basic)).
:- use_module(engine(runtime_control), [set_prolog_flag/2]).

:- concurrent goal_solution_ready/1.

main1(X,Y,IdProc) :-
    set_prolog_flag(gc, off),
    eng_call(do, create, create, IdProc),
    G = '$:'('foo:foo'(X,Y)),
    display(eng_push_goal(G)),nl,
    eng_push_goal(Id,G),
    pause(1),
    (
        eng_goal_solution(Id) -> call(G)
    ;
        retract_fact(goal_solution_ready(Id)),
        display(goal_solution_ready(Id)), nl
    ).
    
do :-
    display(eng_find_goal(Id,Goal)),nl,
    eng_find_goal(Id,Goal),
    call(Goal),
    display(remote_call(Goal)),nl,
    assertz_fact(goal_solution_ready(Id)),
    pause(2).

foo(X,Y) :-
    Z = a,
    Y = X,
    Z = Y,
    X = Z.

main :-
    set_prolog_flag(gc, off),
    main1(X,Y,IdProc),
    display('Result: '), display(main(X,Y)), nl,
    eng_wait(IdProc),
    eng_release(IdProc).


