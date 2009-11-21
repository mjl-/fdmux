implement Testmuxc;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "util0.m";
	util: Util0;
	rev: import util;
include "fdmux.m";
	fdmux: Fdmux;
	Mux: import fdmux;

Testmuxc: module {
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

	(ok, conn) := sys->dial("net!localhost!1234", nil);
	if(ok != 0)
		fail(sprint("dial: %r"));
	fd := conn.dfd;
	say("dialed");

	mux := fdmux->start(fd, 0);

	say("open a");
	fda := mux.open();
	if(fda == nil)
		fail(sprint("open: %r"));
	mux.priority(fda, fdmux->Phigh);

	say("open b");
	fdb := mux.open();
	if(fdb == nil)
		fail(sprint("open: %r"));

	say("writing a");
	if(sys->fprint(fda, "this is a test!\n") < 0)
		fail(sprint("write: %r"));

	say("reading b");
	n := sys->read(fdb, buf := array[128] of byte, len buf);
	if(n < 0)
		fail(sprint("read: %r"));

	say(sprint("client, read %d bytes", n));
	if(sys->write(sys->fildes(2), buf, n) != n)
		fail(sprint("write: %r"));
	say("done");
	fda = fdb = nil;

	mux.stop();
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "testmuxc: %s\n", s);
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
