:- module(map,[test/1,test_all/1]).

:- use_module(engine(runtime_control), [statistics/2]).

%:- determinate(test_all(A),nonvar(A)).

test_all(A) :-
    A>0,
    goal_all(B,C,D,E,F,G),
    H is A-1,
    test_all(H).
test_all(0).

%:- determinate(next(A,B),(nonvar(A),nonvar(B))).

next(blue,yellow).
next(blue,red).
next(blue,green).
next(yellow,blue).
next(yellow,red).
next(yellow,green).
next(red,blue).
next(red,yellow).
next(red,green).
next(green,blue).
next(green,yellow).
next(green,red).

%:- determinate(test(A),nonvar(A)).

test(A) :-
    A>0,
    goal(B,C,D,E,F,G),
    H is A-1,
    test(H).
test(0).


goal(A,B,C,D,E,F) :-
    next(A,B),
    next(A,C),
    next(A,E),
    next(A,F),
    next(B,C),
    next(B,D),
    next(B,E),
    next(B,F),
    next(C,D),
    next(C,F),
    next(E,F).

goal_all(A,B,C,D,E,F) :-
    next(A,B),
    next(A,C),
    next(A,E),
    next(A,F),
    next(B,C),
    next(B,D),
    next(B,E),
    next(B,F),
    next(C,D),
    next(C,F),
    next(E,F),
    fail.
goal_all(A,B,C,D,E,F).

go :-
    goal_all(A,B,C,D,E,F).

test:- goal(A,B,C,D,E,F).

%%%%%%%%%%%%%%%%%%%%%

ourmain:-
    statistics(runtime,_),
    ourdo,
    statistics(runtime,[_,T1]),
    write(T1).

%:- determinate(ourdo,true).

ourdo:-
    test,
    fail.
ourdo.
