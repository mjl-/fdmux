Fdmux: module
{
	PATH:	con "/dis/lib/fdmux.dis";

	dflag:	int;
	start:	fn(fd: ref Sys->FD, announce: int): ref Mux;

	Phighest, Phigh, Pnormal, Plow, Plowest, Pend: con iota; # priority's prio
	Local, Remote: con 1<<iota;

	Mux: adt {
		openc:		chan of (ref Sys->FileIO, int, chan of string);
		listenc:	chan of chan of int;
		acceptc:	chan of (ref Sys->FileIO, int, int, chan of string);
		rejectc:	chan of (int, string);
		prioc:		chan of (int, int, int, chan of string); # fd, prio, where
		stopc:		chan of int;
		filegen:	int;

		open:		fn(x: self ref Mux): ref Sys->FD;
		listen:		fn(x: self ref Mux): int;
		accept:		fn(x: self ref Mux, rnum: int): ref Sys->FD;
		reject:		fn(x: self ref Mux, rnum: int, msg: string): int;
		priority:	fn(x: self ref Mux, fd: ref Sys->FD, prio: int, where: int): int;
		stop:		fn(x: self ref Mux);
	};
};
