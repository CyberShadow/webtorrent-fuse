module webtorrent_fuse;

import core.stdc.errno;
import core.sys.posix.signal;
import core.sys.posix.sys.stat;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.conv : to;
import std.algorithm.comparison;
import std.exception;
import std.file;
import std.stdio : stderr;
import std.string;
import std.typecons;

import c.fuse.fuse;

import ae.net.http.common;
import ae.sys.data;
import ae.sys.dataset;
import ae.sys.net;
import ae.sys.net.ae;
import ae.utils.array;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.xml.lite;

pragma(lib, "fuse");

struct FileEntry
{
	ulong size;
	string url;
}
alias FusePath = string; // includes leading /

__gshared
{
	string baseURL;
	FileEntry[FusePath] files;
}

int fuseWrap(scope int delegate() dg) nothrow
{
	try
		return dg();
	catch (ErrnoException e)
	{
		debug stderr.writeln(e).assumeWontThrow;
		return -e.errno;
	}
	catch (FileException e)
	{
		debug stderr.writeln(e).assumeWontThrow;
		return -e.errno;
	}
	catch (Exception e)
	{
		debug stderr.writeln(e).assumeWontThrow;
		return -EIO;
	}
}

int fuseWrap(scope void delegate() dg) nothrow
{
	return fuseWrap({ dg(); return 0; });
}

extern(C) nothrow
{
	int fs_getattr(const char* c_path, stat_t* s)
	{
		return fuseWrap({
			// Is it a file?
			auto path = c_path.fromStringz;
			if (path == "/") path = "";

			if (auto entry = path in files)
			{
				s.st_mode = S_IFREG | S_IRUSR;
				s.st_size = entry.size;
				return 0;
			}

			// Is it a directory?
			foreach (entryPath, ref entry; files)
				if (entryPath.startsWith(path ~ "/"))
				{
					s.st_mode = S_IFDIR | S_IRUSR | S_IXUSR;
					return 0;
				}

			// Not found
			return -ENOENT;
		});
	}

	int fs_read(const char* c_path, char* buf_ptr, size_t size, off_t offset, fuse_file_info* fi)
	{
		return fuseWrap({
			auto path = c_path.fromStringz;
			if (path == "/") path = "";

			auto entry = (path in files).enforce("No such file");
			auto req = new HttpRequest(entry.url);
			auto firstByte = offset;
			auto lastByte = min(offset + size, entry.size) - 1;
			req.headers["Range"] = format("bytes=%d-%d", firstByte, lastByte);
			auto res = net.httpRequest(req);
			enforce(res.status == HttpStatusCode.PartialContent, "Request failed: %s".format(res.statusMessage));
			enforce(res.headers.get("Content-Range", null) == format("bytes %d-%d/%d", firstByte, lastByte, entry.size),
				"Invalid range response: %s".format(res.headers.get("Content-Range", "(none)")));
			auto numBytes = min(size, res.data.bytes.length);
			res.data.bytes[0 .. numBytes].copyTo(buf_ptr[0 .. numBytes].asBytes);
			return numBytes.to!int;
		});
	}

	int fs_readdir(const char* c_path, void* buf, 
		fuse_fill_dir_t filler, off_t /*offset*/, fuse_file_info* fi)
	{
		return fuseWrap({
			auto path = c_path.fromStringz;
			if (path == "/") path = "";

			HashSet!string directories;
			foreach (entryPath, ref entry; files)
				if (entryPath.skipOver(path ~ "/"))
				{
					if (auto parts = entryPath.findSplit("/"))
						directories.add(parts[0]);
					else
						filler(buf, cast(char*)entryPath.toStringz, null, 0);
				}
			foreach (dirPath; directories)
				filler(buf, cast(char*)dirPath.toStringz, null, 0);
				
		});
	}

	// int fs_access(const char* c_path, int mode)
	// {
	// 	return fuseWrap({
	// 		// Is it a file?
	// 		auto path = c_path.fromStringz;
	// 		if (auto entry = path in files)
	// 			return 0;

	// 		// Is it a directory?
	// 		foreach (entryPath, ref entry; files)
	// 			if (entryPath.startsWith(path ~ "/"))
	// 				return 0;

	// 		// Not found
	// 		return -ENOENT;
	// 	});
	// }
}

int webtorrent_fuse(
	Parameter!(string, "Directory path where the webtorrent-fuse virtual filesystem should be created.") mountPath,
	Option!(string, "Base WebTorrent HTTP server URL") baseURL = "http://127.0.0.1:8000",
	Switch!("Run in foreground.", 'f') foreground = false,
	Option!(string[], "Additional FUSE options (e.g. debug).", "STR", 'o') options = null,
)
{
	.baseURL = baseURL;

	{
		auto html = getFile(baseURL ~ "/").assumeUTF.assumeUnique;
		auto document = html.parseDocument!Html5StrictParseConfig;
		files = document["html"]["body"]["ol"]
			.findChildren("li")
			.map!((li) {
				auto a = li["a"];
				auto path = "/" ~ a.text;
				return tuple(path, FileEntry(
					url: baseURL ~ "/" ~ a.attributes["href"].replace(" ", "%20"),
					size: li.text.split("(")[$-1].findSplit(" bytes)")[0].to!ulong,
				));
			})
			.assocArray;
	}

	fuse_operations fsops;
	fsops.getattr = &fs_getattr;
	fsops.read = &fs_read;
	fsops.readdir = &fs_readdir;
	// fsops.access = &fs_access;

	string[] args = ["webtorrent-fuse", mountPath, "-o%-(%s,%)".format(options)];
	args ~= "-s"; // single-threaded
	if (foreground)
		args ~= "-f";
	auto c_args = new char*[args.length];
	foreach (i, arg; args)
		c_args[i] = cast(char*)arg.toStringz;
	auto f_args = FUSE_ARGS_INIT(cast(int)c_args.length, c_args.ptr);

	stderr.writeln("Starting FUSE filesystem.");
	scope(success) stderr.writeln("webtorrent-fuse exiting.");
	return fuse_main(f_args.argc, f_args.argv, &fsops, null);
}

mixin main!(funopt!webtorrent_fuse);
