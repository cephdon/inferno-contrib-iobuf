implement IOBuf;

include	"sys.m";
	sys: Sys;
	sprint: import sys;
include "../../module/iobuf.m";


init()
{
	sys = load Sys Sys->PATH;
}

ReadBuf.new(fd: ref Sys->FD, bufsize: int): ref ReadBuf
{
	r := ref ReadBuf;
	r.buf		= array[bufsize] of byte;
	r.s		= 0;
	r.e		= 0;
	r.setsep("\n", 1);
	r.fd		= fd;
	r.reader	= sysread;
	return r;
}

ReadBuf.newc(queuesize, bufsize: int): ref ReadBuf
{
	r := ReadBuf.new(nil, bufsize);
	r.queue		= chan[queuesize] of array of byte;
	r.pending	= chan[1] of (array of byte, Sys->Rwrite);
	r.is_pending	= chan[1] of int;
	r.reader	= chanread;
	return r;
}

ReadBuf.setsep(r: self ref ReadBuf, sep: string, strip: int)
{
	r.sep	= array of byte sep;
	r.strip	= strip;
}


ReadBuf.reads(r: self ref ReadBuf): array of byte
{
	if(len r.sep != 1)
		raise "iobuf:multibyte separator not implemented yet";
	c := r.sep[0];

	for(;;){
		for(i := r.s; i < r.e; i++)
			if(r.buf[i] == c){
				s := r.s;
				r.s = i+1;
				return r.buf[s:i + 1 * !r.strip];
			}

		if(r.s != 0){
			r.buf[0:] = r.buf[r.s:r.e];
			r.e -= r.s;
			r.s = 0;
		}
		if(r.e == len r.buf)
			raise "iobuf:no separator found in full buffer";
		
		if(r.reader(r) == 0)
			return nil;
	}
}

sysread(r: ref ReadBuf): int
{
	n := sys->read(r.fd, r.buf[r.e:], len r.buf - r.e);
	if(n < 0)
		raise sprint("iobuf:%r");
	r.e += n;
	return n;
}

bufread(r: ref ReadBuf, buf: array of byte): int
{
	n := len buf;
	if(len r.buf - r.e < n)
		n = len r.buf - r.e;
	r.buf[r.e:] = buf[0:n];
	r.e += n;
	if(len buf > n)
		r.leftover = buf[n:];
	else
		r.leftover = nil;
	return n;
}

chanread(r: ref ReadBuf): int
{
	if(r.leftover != nil)
		return bufread(r, r.leftover);

	alt{
	buf := <-r.queue =>
		if(buf == nil)
			return 0;
		else
			return bufread(r, buf);
	(buf, wc) := <-r.pending =>
		n := len buf;
		alt{
		buf2 := <-r.queue =>
			r.queue <-= buf;
			buf = buf2;
		* => 
			;
		}
		<-r.is_pending;
		wc <-= (n, nil);
		return bufread(r, buf);
	}
}

ReadBuf.readn(r: self ref ReadBuf, n: int): array of byte
{
	if(r.e - r.s >= n){
		s := r.s;
		r.s += n;
		return r.buf[s:r.s];
	}
	
	oldbuf : array of byte;

	if(len r.buf >= n){
		if(len r.buf - r.s < n){
			r.buf[0:] = r.buf[r.s:r.e];
			r.e -= r.s;
			r.s = 0;
		}
	}
	else{
		oldbuf = r.buf;
		r.buf = array[n] of byte;
		r.buf[0:] = oldbuf[r.s:r.e];
		r.e -= r.s;
		r.s = 0;
	}

	while(r.e - r.s < n)
		if(r.reader(r) == 0)
			n = r.e - r.s;
	
	if(oldbuf == nil){
		s := r.s;
		r.s += n;
		return r.buf[s:r.s];
	}
	else{
		tmp := r.buf;
		r.buf = oldbuf;
		r.s = r.e = 0;
		return tmp;
	}
}

ReadBuf.fill(r: self ref ReadBuf, data: array of byte, wc: Sys->Rwrite)
{
	alt{
	r.is_pending <-= 1 =>
		<-r.is_pending;
		alt{
		r.queue <-= data =>
			wc <-= (len data, nil);
		* =>
			r.is_pending <-= 1;
			r.pending <-= (data, wc);
		}
	* =>
		wc <-= (0, "concurrent writes not supported");
	}
}

WriteBuf.new(fd: ref Sys->FD, bufsize: int): ref WriteBuf
{
	w := ref WriteBuf;
	w.buf		= array[bufsize] of byte;
	w.s		= 0;
	w.e		= 0;
	w.fd		= fd;
	w.writer	= syswrite;
	return w;
}

WriteBuf.newc(bufsize: int): ref WriteBuf
{
	w := WriteBuf.new(nil, bufsize);
	w.pending	= chan[1] of (int, Sys->Rread);
	w.writer	= chanwrite;
	return w;
}

WriteBuf.write(w: self ref WriteBuf, buf: array of byte)
{
	n := 0;

	if(w.e != 0){
		n = len w.buf - w.e;
		if(n > len buf)
			n = len buf;
		w.buf[w.e:] = buf[:n];
		w.e += n;
		if(len w.buf == w.e)
			w.flush();
	}
	
	if(len buf > n){
		blocks := len buf / len w.buf;
		n2 := blocks * len w.buf;
		if(n2 > 0){
			tmp := w.buf;
			w.buf = buf[n:n + n2];
			w.s = 0;
			w.e = n2;
			w.flush();
			w.buf = tmp;
			n += n2;
		}
		w.buf[0:] = buf[n:];
		w.e = len buf - n;
	}

	if(w.writer == chanwrite && w.s != w.e)
		optchanwrite(w);
}

syswrite(w: ref WriteBuf)
{
	n := sys->write(w.fd, w.buf[w.s:w.e], w.e - w.s);
	if(n != w.e - w.s)
		raise sprint("iobuf:%r");
	w.s = 0;
	w.e = 0;
}

chanwrite(w: ref WriteBuf)
{
	(n, rc) := <-w.pending;
	if(n > w.e - w.s)
		n = w.e - w.s;
	rc <-= (w.buf[w.s:w.s + n], nil);
	w.s += n;
}

optchanwrite(w: ref WriteBuf)
{
	alt{
	(n, rc) := <-w.pending =>
		if(n > w.e - w.s)
			n = w.e - w.s;
		rc <-= (w.buf[w.s:w.s + n], nil);
		w.s += n;
	* =>
		;
	}
}

WriteBuf.flush(w: self ref WriteBuf)
{
	while(w.s != w.e)
		w.writer(w);
}

WriteBuf.request(w: self ref WriteBuf, n: int, rc: Sys->Rread)
{
	alt{
	w.pending <-= (n, rc) =>
		;
	* =>
		rc <-= (nil, "concurrent reads not supported");
	}
}
