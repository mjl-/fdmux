# data is wrapped in packets, the header is 5 bytes:
# 2 bytes rnum, 1 byte type (ctl=0, data=1), 2 bytes length, length bytes data.
# rnum is the remote num, the number of the channel on the sender side.
# ctl messages can always be written.  data messages must be within the bounds of the window.
# the ctl messages open/destroy nums, and increase the windows.
# 
# each logical channel is a fileio, bidirectional.
# we always accept data from the network.  if remote sends past the channel window, the whole mux dies.
# we only accept new fileio writes when its sender window > 0.
# channels can have priorities for writing: highest, high, normal, low, lowest.
# when something can be written to the network, we first exhaust higher priority
# in round-robin fashion (per write, not number of bytes), then the next in line.
# remote priority (for writing from remote to local for a channel) can be set by a ctl message.
#
# ctl messages are simple utf-8 quoted strings, no newline, the first word is the command:
# - open
# - accept num
# - reject num string
# - close
# - win x
# - prio x  (highest=0, high=1, normal=2, low=3, lowest=4)
# - error string
#
# for accept & reject, num is the number of the channel from which the open was sent.
# the num in the packet header is the number the accepting side assigned to it.
# for rejects, this number can be ignored, i'm setting it to 0.

implement Fdmux;

include "sys.m";
	sys: Sys;
	sprint, aprint: import sys;
include "string.m";
	str: String;
include "util0.m";
	util: Util0;
	hex, min, max, kill, pid, p16, g16, l2a, rev: import util;
include "tables.m";
	tables: Tables;
	Table: import tables;
include "fdmux.m";

Ctl, Data: con iota;
Datamax:	con 64*1024-1;
Windowmax:	con 128*1024;	# max & default window size
Windowhold:	con 16*1024;	# only send win messages for window >= Windowhold

Muxdat: adt {
	x:	ref Mux;
	fd:	ref Sys->FD;
	listener:	chan of int;
	listenrnums:	list of int;  # incoming new nums, not yet returned to listen
	waitrnums:	list of int;  # incoming new nums, waiting for accept or reject
	llinks,
	rlinks,
	fdlinks:	ref Tables->Table[ref Link];  # lnum,rnum,fd -> link
	lnumgen:	int;
	writing:	int;	# whether netwriter is busy
	writec:		chan of array of byte;  # to netwriter
	readerpid,
	writerpid,
	srvpid:		int;
	announce:	int;	# whether we accept listens at all
	rings:		array of ref Ring; # indexed by priority
	err:		string;	# connection died, error message
	stop:		int;
};

Ring: adt {
	a:	array of int;	# of lnums
	i:	int;		# next to try
	prio:	int;		# priority for this ring

	new:	fn(prio: int): ref Ring;
	add:	fn(r: self ref Ring, lnum: int);
	del:	fn(r: self ref Ring, lnum: int);
};

Link: adt {
	lnum,			# locally assigned, for outgoing messages
	rnum:		int;	# remotely assigned, for incoming messages
	fdnum:		int;	# fd on library-user side
	prio:		int;	# current priority
	fio:		ref Sys->FileIO;
	fid:		int;	# currently opened fid, may be -1 if none yet
	fiopid:		int;	# pid of fiopass
	recvwin,
	sendwin:	int;
	rreqs:		list of ref (int, int, Sys->Rread); # count, fid, rc
	rbufs:		list of array of byte;
	nread:		int;	# number of bytes to increase recvwin with
	wreqs:		list of ref (int, array of byte, int, Sys->Rwrite); # count, data, fid, wc;  only data is set for ctl messages!
	wreqnb:		int;	# number of bytes of data (not ctl) in wreqs
	err:		string;	# error for new reads/writes
	lclosed,
	rclosed:	int;	# closed
	openrc:		chan of string;	# may be nil, respond to when accept/reject comes in
	writeok:	int;	# whether fiopass is receiving writes
	writeokc:	chan of int;	# signal to fiopass that it should receive writes
};

init()
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
}

Mux.open(x: self ref Mux): ref Sys->FD
{
	gen := x.filegen++;
	f := sprint("fdmux.%d.%d", pid(), gen);
	fio := sys->file2chan("/chan", f);
	if(fio == nil)
		return nil;

	fd := sys->open("/chan/"+f, Sys->ORDWR);
	if(fd == nil)
		return nil;
	x.openc <-= (fio, fd.fd, rc := chan of string);
	err := <-rc;
	if(err != nil) {
		sys->werrstr(err);
		return nil;
	}
	return fd;
}

Mux.listen(x: self ref Mux): int
{
	rc := chan of int;
	x.listenc <-= rc;
	return <-rc;
}

Mux.accept(x: self ref Mux, rnum: int): ref Sys->FD
{
	f := sprint("fdmux.%d.%d", pid(), rnum);
	fio := sys->file2chan("/chan", f);
	if(fio == nil)
		return nil;

	fd := sys->open("/chan/"+f, Sys->ORDWR);
	if(fd == nil) {
		x.rejectc <-= (rnum, "open failed");
		return nil;
	}

	x.acceptc <-= (fio, rnum, fd.fd, rc := chan of string);
	err := <-rc;
	if(err != nil) {
		sys->werrstr(err);
		return nil;
	}
	return fd;
}

Mux.reject(x: self ref Mux, rnum: int, msg: string): int
{
	x.rejectc <-= (rnum, msg);
	return 0;
}

Mux.priority(x: self ref Mux, fd: ref Sys->FD, prio: int, where: int): int
{
	x.prioc <-= (fd.fd, prio, where, rc := chan of string);
	err := <-rc;
	if(err != nil) {
		sys->werrstr(err);
		return -1;
	}
	return 0;
}

Mux.stop(x: self ref Mux)
{
	x.stopc <-= 1;
}

Ring.new(prio: int): ref Ring
{
	return ref Ring (array[0] of int, 0, prio);
}

Ring.add(r: self ref Ring, lnum: int)
{
	a := array[len r.a+1] of int;
	a[:] = r.a;
	a[len r.a] = lnum;
	r.a = a;
}

Ring.del(r: self ref Ring, lnum: int)
{
	for(i := 0; i < len r.a; i++) {
		if(r.a[i] == lnum) {
			a := array[len r.a-1] of int;
			a[:] = r.a[:i];
			a[i:] = r.a[i+1:];
			r.a = a;
			r.i = max(0, min(r.i, len r.a-1));
			return;
		}
	}
}

start(fd: ref Sys->FD, announce: int): ref Mux
{
	if(sys == nil)
		init();
	if(dflag) say("start");

	xd := ref Muxdat;
	xd.fd = fd;
	xd.llinks = xd.llinks.new(31, nil);
	xd.rlinks = xd.rlinks.new(31, nil);
	xd.fdlinks = xd.fdlinks.new(31, nil);
	xd.writec = chan of array of byte;
	xd.writing = 0;
	xd.lnumgen = 1;
	if(announce)
		xd.lnumgen += 10; # for excercising different remote & local nums
	xd.announce = announce;
	xd.rings = array[Pend] of ref Ring;
	for(i := 0; i < len xd.rings; i++)
		xd.rings[i] = Ring.new(i);
	xd.stop = 0;

	xd.x = x := ref Mux;
	x.openc = chan of (ref Sys->FileIO, int, chan of string);
	x.listenc = chan of chan of int;
	x.acceptc = chan of (ref Sys->FileIO, int, int, chan of string);
	x.rejectc = chan of (int, string);
	x.prioc = chan of (int, int, int, chan of string);
	x.stopc = chan of int;
	x.filegen = 1;

	spawn srv(xd, fd);
	return x;
}

srv(xd: ref Muxdat, fd: ref Sys->FD)
{
	x := xd.x;

	xd.srvpid = pid();
	pidc := chan of int;
	readc := chan of (int, int, array of byte, string);
	writtenc := chan of string;
	spawn netreader(fd, readc, pidc);
	xd.readerpid = <-pidc;
	spawn netwriter(fd, xd.writec, writtenc, pidc);
	xd.writerpid = <-pidc;

	fioreadc := chan of (ref Link, (int, int, int, Sys->Rread));
	fiowritec := chan of (ref Link, (int, array of byte, int, Sys->Rwrite));

	if(dflag) say("srv, starting");
	for(;;) alt {
	rc := <-x.listenc =>
		if(dflag) say("srv, listen");
		if(xd.listener != nil || xd.err != nil) {
			rc <-= -1;
			continue;
		}
		xd.listener = rc;
		dolistens(xd);

	(fio, rnum, fdnum, rc) := <-x.acceptc =>
		if(dflag) say("srv, accept");
		if(xd.err != nil) {
			rc <-= xd.err;
			continue;
		}
		if(!has(xd.waitrnums, rnum)) {
			rc <-= "no such rnum pending";
			continue;
		}
		xd.waitrnums = del(xd.waitrnums, rnum);

		l := newlink(xd.lnumgen++, rnum, fdnum, fio, nil);
		xd.rings[Pnormal].add(l.lnum);
		xd.llinks.add(l.lnum, l);
		xd.rlinks.add(l.rnum, l);
		xd.fdlinks.add(l.fdnum, l);
		spawn fiopass(l, fioreadc, fiowritec, pidc);
		l.fiopid = <-pidc;

		wctl(xd, l, sprint("accept %d", rnum));
		l.recvwin = Windowmax;
		wctl(xd, l, sprint("win %d", l.recvwin));
		rc <-= nil;

	(rnum, err) := <-x.rejectc =>
		if(dflag) say("srv, reject");
		xd.waitrnums = del(xd.waitrnums, rnum);
		spawn write0(fd, pack(0, Ctl, aprint("reject %d %q", rnum, err)));

	(fdnum, prio, where, rc) := <-x.prioc =>
		if(dflag) say("srv, prio");
		if(xd.err != nil) {
			rc <-= xd.err;
			continue;
		}
		l := xd.fdlinks.find(fdnum);
		if(l == nil) {
			rc <-= "cannot find link";
			continue;
		}
		if(where&Local)
			setprio(xd, l, prio);
		if(where&Remote)
			wctl(xd, l, sprint("prio %d", prio));
		rc <-= nil;

	<-x.stopc =>
		if(dflag) say("srv, stop");
		xd.stop = 1;
		for(l := all(xd.llinks); l != nil; l = tl l) {
			ll := hd l;
			if(!ll.lclosed) {
				ll.lclosed = 1;
				wctl(xd, ll, "close");
			}
			tryclose(xd, ll);
		}

	(rnum, typ, buf, err) := <-readc =>
		if(dflag) say(sprint("srv, netread, rnum %d, n %d, err %q", rnum, len buf, err));
		if(err != nil) {
			error(xd, err);
			continue;
		}

		l := xd.rlinks.find(rnum);
		if(l != nil && l.rclosed) {
			error(xd, "remote sent to link it closed");
			continue;
		}
		if(typ == Ctl) {
			ctl(xd, rnum, buf);
			continue;
		}
		if(typ != Data) {
			error(xd, sprint("bogus type %d from remote", typ));
			continue;
		}

		if(l == nil) {
			error(xd, sprint("no such rnum %d, bad remote", rnum));
			continue;
		}
		l.recvwin -= len buf;
		if(l.recvwin < 0) {
			error(xd, "remote sent data past window");
			continue;
		}
		l.rbufs = buf::l.rbufs;
		linkreads(xd, l);

	err := <-writtenc =>
		if(dflag) say("srv, written");
		if(err != nil) {
			error(xd, err);
			continue;
		}
		xd.writing = 0;
		nextwrite(xd);

	(fio, fdnum, rc) := <-x.openc =>
		if(dflag) say("srv, open");
		if(xd.err != nil) {
			rc <-= xd.err;
			continue;
		}
		l := newlink(xd.lnumgen++, -1, fdnum, fio, rc);
		xd.rings[Pnormal].add(l.lnum);
		xd.llinks.add(l.lnum, l);
		xd.fdlinks.add(l.fdnum, l);
		spawn fiopass(l, fioreadc, fiowritec, pidc);
		l.fiopid = <-pidc;
		wctl(xd, l, "open");

	(l, tup) := <-fioreadc =>
		(nil, count, fid, rc) := tup;
		if(dflag) say(sprint("srv, fioread, count %d, fid %d, rc nil %d", count, fid, rc==nil));
		if(rc == nil)
			continue;
		if(l.fid < 0)
			l.fid = fid;
		if(l.fid != fid)
			raise "bogus fid?";
		l.rreqs = ref (count, fid, rc)::l.rreqs;
		linkreads(xd, l);

	(l, tup) := <-fiowritec =>
		l.writeok = 0;
		(nil, data, fid, wc) := tup;
		if(dflag) say(sprint("srv, fiowrite, len data %d, fid %d, wc nil %d", len data, fid, wc==nil));
		if(wc == nil) {
			if(!l.lclosed) {
				l.lclosed = 1;
				wctl(xd, l, "close");
			}
			l.fid = -1;
			tryclose(xd, l);
			continue;
		}
		if(l.fid < 0)
			l.fid = fid;
		if(l.fid != fid)
			raise "bogus fid?";
		l.wreqs = ref (len data, data, fid, wc)::l.wreqs;
		l.wreqnb += len data;
		nextwrite(xd);
		if(l.wreqnb < l.sendwin && !l.writeok) {
			l.writeok = 1;
			l.writeokc <-= 1;
		}
	}
}

write0(fd: ref Sys->FD, buf: array of byte)
{
	sys->write(fd, buf, len buf);
}

cmds := array[] of {
"open", "accept", "reject", "close", "win", "prio", "error"
};
args := array[] of {
0, 1, 2, 0, 1, 1, 1,
};
ctl(xd: ref Muxdat, rnum: int, buf: array of byte)
{
	s := string buf;
	if(dflag) say("ctl: "+s);
	t := l2a(str->unquoted(s));
	if(len t == 0 || (i := index(cmds, t[0])) < 0 || len t-1 != args[i])
		return error(xd, "bad ctl message from remote");

	case t[0] {
	"open" =>
		if(!xd.announce) {
			spawn write0(xd.fd, pack(0, Ctl, aprint("reject %d %q", rnum, "refused")));
			return;
		}
		if(has(xd.listenrnums, rnum) || has(xd.waitrnums, rnum))
			return error(xd, "open for already pending rnum");
		if(xd.rlinks.find(rnum) != nil)
			return error(xd, "open for already open rnum");
		xd.listenrnums = rnum::xd.listenrnums;
		dolistens(xd);

	"accept" =>
		lnum := int t[1];
		l := xd.llinks.find(lnum);
		if(l == nil)
			return error(xd, "bogus accept from remote");
		if(l.rnum >= 0)
			return error(xd, "double accept from remote");
		l.rnum = rnum;
		xd.rlinks.add(l.rnum, l);
		l.openrc <-= nil;
		l.openrc = nil;
		l.recvwin = Windowmax;
		wctl(xd, l, sprint("win %d", l.recvwin));
		
	"reject" =>
		lnum := int t[1];
		msg := t[2];
		l := xd.llinks.find(lnum);
		if(l == nil)
			return error(xd, "bogus reject from remote");
		if(l.rnum >= 0)
			return error(xd, "reject after accept, from remote");
		l.openrc <-= "rejected: "+msg;
		l.openrc = nil;
		l.err = msg;
		l.lclosed = l.rclosed = 1;
		tryclose(xd, l);

	"close" =>
		l := xd.rlinks.find(rnum);
		if(l == nil)
			return error(xd, "remote sent bogus close");
		l.rclosed = 1;
		if(!l.lclosed) {
			l.lclosed = 1;
			wctl(xd, l, "close");

			for(r := l.rreqs; r != nil; r = tl r) {
				(nil, nil, rc) := *hd r;
				rc <-= (array[0] of byte, nil);
			}
		}
		tryclose(xd, l);

	"win" =>
		n := int t[1];
		l := xd.rlinks.find(rnum);
		if(l == nil)
			return error(xd, "remote sent bogus win");
		l.sendwin += n;
		if(l.sendwin > 0 && !l.writeok) {
			l.writeok = 1;
			l.writeokc <-= 1;
		}
		nextwrite(xd);

	"prio" =>
		prio := int t[1];
		l := xd.rlinks.find(rnum);
		if(l == nil)
			return error(xd, "remote sent bogus prio0");
		if(prio < 0 || prio >= Pend)
			return error(xd, "remote sent bogus prio1");
		setprio(xd, l, prio);

	"error" =>
		msg := t[1];
		l := xd.rlinks.find(rnum);
		if(l != nil)
			return error(xd, "remote send bogus error");
		linkerror(xd, l, msg);
	}
}

setprio(xd: ref Muxdat, l: ref Link, prio: int)
{
	if(prio == l.prio)
		return;
	xd.rings[l.prio].del(l.lnum);
	l.prio = prio;
	xd.rings[l.prio].add(l.lnum);
}

newlink(lnum, rnum, fdnum: int, fio: ref Sys->FileIO, rc: chan of string): ref Link
{
	return ref Link (lnum, rnum, fdnum, Pnormal, fio, -1, -1, 0, 0, nil, nil, 0, nil, 0, "", 0, 0, rc, 0, chan[1] of int);
}

dolistens(xd: ref Muxdat)
{
	if(dflag) say(sprint("dolistens, len listenrnums %d, listener nil %d", len xd.listenrnums, xd.listener==nil));
	if(xd.listenrnums == nil || xd.listener == nil)
		return;
	l := revint(xd.listenrnums);
	rnum := hd l;
	if(dflag) say(sprint("dolistens, returning rnum %d", rnum));
	xd.listenrnums = revint(tl l);
	xd.listener <-= rnum;
	xd.listener = nil;
	xd.waitrnums = rnum::xd.waitrnums;
}

error(xd: ref Muxdat, err: string)
{
	if(dflag) say("error: "+err);
	xd.err = err;
	for(l := all(xd.llinks); l != nil; l = tl l)
		linkerror(xd, hd l, err);
}

linkerror(xd: ref Muxdat, l: ref Link, err: string)
{
	for(r := l.rreqs; r != nil; r = tl r) {
		(nil, nil, rc) := *hd r;
		rc <-= (nil, err);
	}

	for(w := l.wreqs; w != nil; w = tl w) {
		(nil, nil, nil, wc) := *hd w;
		if(wc != nil)
			wc <-= (-1, err);
	}
	l.rreqs = nil;
	l.rbufs = nil;
	l.wreqs = nil;
	l.err = err;
	if(!l.lclosed) {
		l.lclosed = 1;
		wctl(xd, l, "close");
	}
	tryclose(xd, l);
}

linkreads(xd: ref Muxdat, l: ref Link)
{
	if(dflag) say(sprint("linkreads, lnum %d, rnum %d, recvwin %d, %d rreqs, %d rbufs, err %q, lclosed %d, rclosed %d",
		l.lnum, l.rnum, l.recvwin, len l.rreqs, len l.rbufs, l.err, l.lclosed, l.rclosed));

	if(l.rclosed) {
		while(l.rreqs != nil) {
			(nil, nil, rc) := *hd l.rreqs;
			l.rreqs = tl l.rreqs;
			rc <-= (array[0] of byte, nil);
		}
		return;
	}

	while(l.rreqs != nil && l.rbufs != nil) {
		l.rreqs = rev(l.rreqs);
		l.rbufs = rev(l.rbufs);

		(count, nil, rc) := *hd l.rreqs;
		l.rreqs = rev(tl l.rreqs);

		buf := array[count] of byte;
		o := 0;
		while(o < count && l.rbufs != nil) {
			rbuf := hd l.rbufs;
			l.rbufs = tl l.rbufs;

			n := min(count-o, len rbuf);
			buf[o:] = rbuf[:n];
			o += n;
			if(n < len rbuf)
				l.rbufs = rbuf[n:]::l.rbufs;
		}
		rc <-= (buf[:o], nil);
		l.nread += o;

		l.rbufs = rev(l.rbufs);
	}
	if(tryclose(xd, l))
		return;

	if(l.lclosed || l.err != nil) {
		resp := (array[0] of byte, l.err);
		while(l.rreqs != nil) {
			(nil, nil, rc) := *hd l.rreqs;
			l.rreqs = tl l.rreqs;
			rc <-= resp;
		}
		return;
	}

	if(l.nread >= Windowhold) {
		wctl(xd, l, sprint("win %d", l.nread));
		l.recvwin += l.nread;
		l.nread = 0;
	}
}

linkwrite(xd: ref Muxdat, l: ref Link): int
{
	if(dflag) say(sprint("linkwrite, lnum %d, rnum %d, sendwin %d, %d wreqs, wreqnb %d, err %q, lclosed %d, rclosed %d",
		l.lnum, l.rnum, l.sendwin, len l.wreqs, l.wreqnb, l.err, l.lclosed, l.rclosed));

	if(l.err != nil) {
		for(w := l.wreqs; w != nil; w = tl w) {
			(nil, nil, nil, wc) := *hd w;
			if(wc != nil)
				wc <-= (-1, l.err);
		}
		l.wreqs = nil;
		return 0;
	}

	if(l.wreqs == nil || l.sendwin == 0 && (hd rev(l.wreqs)).t3 != nil)
		return 0;

	l.wreqs = rev(l.wreqs);
	(origcount, data, fid, wc) := *hd l.wreqs;
	l.wreqs = tl l.wreqs;

	if(wc == nil) {
		xd.writec <-= pack(l.lnum, Ctl, data);
	} else {
		n := min(Datamax, min(l.sendwin, len data));
		xd.writec <-= pack(l.lnum, Data, data[:n]);
		l.sendwin -= n;
		l.wreqnb -= n;
		if(n < len data)
			l.wreqs = ref (origcount, data[n:], fid, wc)::l.wreqs;
		else
			wc <-= (origcount, nil);
	}
	xd.writing = 1;
	l.wreqs = rev(l.wreqs);
	tryclose(xd, l);

	return 1;
}

tryclose(xd: ref Muxdat, l: ref Link): int
{
	closed := l.rclosed && l.lclosed && l.fid < 0 && l.wreqs == nil && l.rbufs == nil;
	if(closed) {
		if(dflag) say(sprint("killing link, lnum %d", l.lnum));
		kill(l.fiopid);
		xd.llinks.del(l.lnum);
		xd.rlinks.del(l.rnum);
		xd.fdlinks.del(l.fdnum);
		xd.rings[l.prio].del(l.lnum);
	}

	if(xd.stop && len all(xd.llinks) == 0) {
		if(dflag) say("killing srv");
		kill(xd.readerpid);
		kill(xd.writerpid);
		kill(xd.srvpid); # self
	}
	return closed;
}

pack(lnum: int, typ: int, d: array of byte): array of byte
{
	buf := array[2+1+2+len d] of byte;
	o := 0;
	o = p16(buf, o, lnum);
	buf[o++] = byte typ;
	o = p16(buf, o, len d);
	buf[o:] = d;
	return buf;
}

wctl(xd: ref Muxdat, l: ref Link, s: string)
{
	if(dflag) say("wctl: "+s);
	l.wreqs = ref (0, array of byte s, -1, nil)::l.wreqs;
	nextwrite(xd);
}

nextwrite(xd: ref Muxdat)
{
	if(xd.writing)
		return;

	for(i := 0; i < len xd.rings; i++) {
		r := xd.rings[i];
		n := len r.a;
		while(n-- > 0) {
			lnum := r.a[r.i];
			r.i = (r.i+1)%len r.a;
			l := xd.llinks.find(lnum);
			if(linkwrite(xd, l))
				return;
		}
	}
}

fiopass(l: ref Link, fioreadc: chan of (ref Link, (int, int, int, Sys->Rread)), fiowritec: chan of (ref Link, (int, array of byte, int, Sys->Rwrite)), pidc: chan of int)
{
	pidc <-= pid();

	boguswritec := chan of (int, array of byte, int, Sys->Rwrite);
	writec := boguswritec;
	for(;;) alt {
	r := <-l.fio.read =>
		fioreadc <-= (l, r);
	r := <-writec =>
		fiowritec <-= (l, r);
		writec = boguswritec;
	<-l.writeokc =>
		writec = l.fio.write;
	}
}

netreader(fd: ref Sys->FD, readc: chan of (int, int, array of byte, string), pidc: chan of int)
{
	pidc <-= pid();
	hdr := array[2+1+2] of byte;
	for(;;) {
		n := sys->readn(fd, hdr, len hdr);
		if(n < 0) {
			readc <-= (-1, 0, nil, sprint("read: %r"));
			break;
		}
		if(n == 0) {
			readc <-= (-1, 0, nil, "eof");
			break;
		}
		if(n != len hdr) {
			readc <-= (-1, 0, nil, "short read on header");
			break;
		}
		(rnum, nil) := g16(hdr, 0);
		typ := int hdr[2];
		(length, nil) := g16(hdr, 2+1);
		buf := array[length] of byte;
		n = sys->readn(fd, buf, len buf);
		if(n < 0) {
			readc <-= (-1, 0, nil, sprint("read: %r"));
			break;
		}
		if(n != len buf) {
			readc <-= (-1, 0, nil, "short read");
			break;
		}
		readc <-= (rnum, typ, buf, nil);
	}
}

netwriter(fd: ref Sys->FD, writec: chan of array of byte, writtenc: chan of string, pidc: chan of int)
{
	pidc <-= pid();
	for(;;) {
		buf := <-writec;
		if(sys->write(fd, buf, len buf) != len buf) {
			writtenc <-= sprint("%r");
			break;
		}
		writtenc <-= nil;
	}
}

all[T](t: ref Table[T]): list of T
{
	r: list of T;
	for(i := 0; i < len t.items; i++)
		for(l := t.items[i]; l != nil; l = tl l)
			r = (hd l).t1::r;
	return r;
}

revint(l: list of int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		r = hd l::r;
	return r;
}

has(l: list of int, e: int): int
{
	for(; l != nil; l = tl l)
		if(hd l == e)
			return 1;
	return 0;
}

del(l: list of int, e: int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		if(hd l != e)
			r = hd l::r;
	return revint(r);
}

index(a: array of string, e: string): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == e)
			return i;
	return -1;
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "fdmux: %s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}
