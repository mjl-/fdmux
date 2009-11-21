implement Testmuxs;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "util0.m";
	util: Util0;
	l2a: import util;
include "fdmux.m";
	fdmux: Fdmux;
	Mux: import fdmux;

Testmuxs: module {
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

dflag: int;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	fdmux = load Fdmux Fdmux->PATH;

	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage(arg->progname());
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	fdmux->dflag = dflag++;
		* =>
			arg->usage();
		}
	args = arg->argv();
	if(args != nil)
		arg->usage();

	say("announcing...");
	(aok, aconn) := sys->announce("net!localhost!1234");
	if(aok < 0)
		fail(sprint("announce: %r"));
	say("announced");
	for(;;) {
		(ok, conn) := sys->listen(aconn);
		if(ok < 0)
			fail(sprint("listen: %r"));
		fd := sys->open(conn.dir+"/data", Sys->ORDWR);
		if(fd == nil)
			fail(sprint("open: %r"));
		spawn srv(fd);
		conn.cfd = fd = nil;
	}
}

srv(fd: ref Sys->FD)
{
	say("srv, new");
	mux := fdmux->start(fd, 1);

	say("listen a");
	numa := mux.listen();
	if(numa < 0)
		fail(sprint("fdmux listen: %r"));
	say(sprint("listen for a, num %d", numa));
	fda := mux.accept(numa);
	if(fda == nil)
		fail(sprint("accept a: %r"));

	say("listen b");
	numb := mux.listen();
	if(numb < 0)
		fail(sprint("fdmux listen: %r"));
	say(sprint("listen for b, num %d", numb));
	fdb := mux.accept(numb);
	if(fdb == nil)
		fail(sprint("accept b: %r"));
	mux.priority(fdb, Fdmux->Phigh);

	say("reading & writing...");
	buf := array[1024] of byte;
	for(;;) {
		n := sys->read(fda, buf, len buf);
		say(sprint("read %d", n));
		if(n < 0) {
			err := sprint("read: %r");
			mux.stop();
			fail(err);
		}
		if(n == 0)
			break;
		if(sys->write(fdb, buf, n) != n) {
			err := sprint("write: %r");
			mux.stop();
			fail(err);
		}
		say("wrote");
	}
	mux.stop();
	say("done");
	
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "testmuxs: %s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

fail(s: string)
{
	warn(s);
	raise "fail:"+s;
}
