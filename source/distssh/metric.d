/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module distssh.metric;

import logger = std.experimental.logger;
import std.algorithm : map, filter, splitter;
import std.datetime : Duration;
import std.exception : collectException;
import std.typecons : Nullable;

import distssh.types;

/** Login on host and measure its load.
 *
 * Params:
 *  h = remote host to check
 *
 * Returns: the Load of the remote host
 */
Load getLoad(Host h, Duration timeout) nothrow {
    import std.conv : to;
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.file : thisExePath;
    import std.process : tryWait, pipeProcess, kill, wait, escapeShellFileName;
    import std.range : takeOne, retro;
    import std.stdio : writeln;
    import core.time : dur;
    import core.sys.posix.signal : SIGKILL;
    import distssh.timer : IntervalSleep;

    enum ExitCode {
        none,
        error,
        timeout,
        ok,
    }

    ExitCode exit_code;

    Nullable!Load measure() {
        auto sw = StopWatch(AutoStart.yes);

        // 25 because it is at the perception of human "lag" and less than the 100
        // msecs that is the intention of the average delay.
        auto loop_sleep = IntervalSleep(25.dur!"msecs");

        immutable abs_distssh = thisExePath;
        auto res = pipeProcess(["ssh", "-q"] ~ sshNoLoginArgs ~ [
                h, abs_distssh.escapeShellFileName, "localload"
                ]);

        while (exit_code == ExitCode.none) {
            auto st = res.pid.tryWait;

            if (st.terminated && st.status == 0) {
                exit_code = ExitCode.ok;
            } else if (st.terminated && st.status != 0) {
                exit_code = ExitCode.error;
            } else if (sw.peek >= timeout) {
                exit_code = ExitCode.timeout;
                res.pid.kill(SIGKILL);
                // must read the exit or a zombie process is left behind
                res.pid.wait;
            } else {
                // sleep to avoid massive CPU usage
                loop_sleep.tick;
            }
        }
        sw.stop;

        Nullable!Load rval;

        if (exit_code != ExitCode.ok)
            return rval;

        try {
            string last_line;
            foreach (a; res.stdout.byLineCopy) {
                last_line = a;
            }

            rval = Load(last_line.to!double, sw.peek);
        } catch (Exception e) {
            logger.trace(res.stdout).collectException;
            logger.trace(res.stderr).collectException;
            logger.trace(e.msg).collectException;
        }

        return rval;
    }

    try {
        auto r = measure();
        if (!r.isNull)
            return r.get;
    } catch (Exception e) {
        logger.trace(e.msg).collectException;
    }

    return Load(int.max, 3600.dur!"seconds", true);
}

/**
 * #SPC-load_balance
 * #SPC-best_remote_host
 */
struct RemoteHostCache {
    import std.array : array;

    HostLoad[] remoteByLoad;

    static auto make(string dbPath, const Host[] cluster) nothrow {
        import distssh.daemon : startDaemon;
        import distssh.database;
        import std.algorithm : sort;

        try {
            auto db = openDatabase(dbPath);
            startDaemon(db);
            db.syncCluster(cluster);
            auto servers = db.getServerLoads(cluster);
            db.removeUnusedServers(servers.unused);
            return RemoteHostCache(servers.online.sort!((a, b) => a[1] < b[1]).array);
        } catch (Exception e) {
            logger.error(e.msg).collectException;
        }
        return RemoteHostCache.init;
    }

    /// Returns: the lowest loaded server.
    Host randomAndPop() @safe nothrow {
        import std.range : take;
        import std.random : randomSample;

        assert(!empty, "should never happen");

        auto rval = remoteByLoad[0][0];

        try {
            auto topX = remoteByLoad.filter!(a => !a[1].unknown).array;
            if (topX.length == 0) {
                rval = remoteByLoad[0][0];
            } else if (topX.length < 3) {
                rval = topX[0][0];
            } else {
                rval = topX.take(3).randomSample(1).front[0];
            }
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }

        remoteByLoad = remoteByLoad.filter!(a => a[0] != rval).array;

        return rval;
    }

    Host front() @safe pure nothrow {
        assert(!empty);
        return remoteByLoad[0][0];
    }

    void popFront() @safe pure nothrow {
        assert(!empty);
        remoteByLoad = remoteByLoad[1 .. $];
    }

    bool empty() @safe pure nothrow {
        return remoteByLoad.length == 0;
    }
}