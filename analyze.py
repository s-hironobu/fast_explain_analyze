"""
 analyze.py

 Usage: python analyze.py [file|dir]

   No argument: aggregate ./pgsql-pg20 (and ./pgsql, ./pgsql-pg19 of the
                older bases), whichever have logs.
   dir:         aggregate the logs in that directory.
   file:        aggregate a single log file.

 Copyright (c) 2025-2026, Hironobu Suzuki @ interdb.jp
"""

import sys
import os
import re


# Calculate avg and unbiased variance.
def calc(d):
    N = 0
    S = 0.0
    V = 0.0

    for x in d:
        N += 1
        S += x
        # Youngs and Cramer method
        if 1 < N:
            V += (x * N - S) ** 2 / (N * (N - 1))

    avg = (S / N) if N > 0 else None
    var = (V / (N - 1)) if N > 1 else None

    return avg, var


def preprocess(datalist):
    _mode = True

    data1 = []
    data2 = []
    data3 = []
    length = len(datalist)

    _timing = False
    i = -1
    while i < length - 1:
        i += 1

        line = datalist[i]

        # Check Mode
        if i == 0:
            _d = datalist[i].split()
            if _d[1] == "FALSE":
                _mode = False
            continue

        # Skip lines 2 through 7 (6 lines) to omit warm-up and checkpoint data.
        if i < 7:
            continue

        if line.startswith("SELECT"):
            i += 1
            _d = datalist[i].split()
            data1.append(float(_d[1]) / 1000)  # msec -> sec
        elif line.startswith("EXPLAIN"):
            i += 1
            _d = datalist[i].split()

            if _mode == True:
                if _timing == True:
                    data3.append(float(_d[1]) / 1000)  # msec -> sec
                    _timing = False
                else:
                    data2.append(float(_d[1]) / 1000)  # msec -> sec
                    _timing = True
            else:
                data2.append(float(_d[1]) / 1000)  # msec -> sec

        elif line.startswith("CHECKPOINT;"):
            pass
        elif line.startswith("CHECKPOINT"):
            i += 1
        else:
            print("Error: {}".format(line))
            sys.exit(1)

    return [data1, data2, data3]


def displayHeader(with_vs_original=False):
    if with_vs_original:
        print("\tDuration[s] (var. [s^2]) \tOverhead[%]\tvs. original Query1[%]")
        print("---------------------------------------------------------------------")
    else:
        print("\tDuration[s] (var. [s^2]) \tOverhead[%]")
        print("-----------------------------------------------------")


def displaySingleBench(query1, query2, query3=None, orig_avg1=None):
    [avg1, var1] = query1
    [avg2, var2] = query2

    def vs(avg):
        if orig_avg1 is None:
            return ""
        return "\t{:.2f}".format(100 * (avg - orig_avg1) / orig_avg1)

    print("Query1\t{:.4f} \t({:.4f})\tN/A{}".format(avg1, var1, vs(avg1)))
    print(
        "Query2\t{:.4f} \t({:.4f})\t{:.2f}{}".format(
            avg2, var2, 100 * (avg2 - avg1) / avg1, vs(avg2)
        )
    )
    if query3:
        [avg3, var3] = query3
        print(
            "Query3\t{:.4f} \t({:.4f})\t{:.2f}{}".format(
                avg3, var3, 100 * (avg3 - avg1) / avg1, vs(avg3)
            )
        )


# Variants in the order they are displayed.  Variants without logs are
# skipped, so original + alt-wrapper alone work.
VARIANTS = ["original", "alt-wrapper", "only-in-node", "phase-2", "phase-3"]
EXPERIMENTAL = ["only-in-node"]


def label(v):
    return v + (" (experimental)" if v in EXPERIMENTAL else "")


def variantFiles(base_dir, v):
    """Round logs <v>.r1.log, <v>.r2.log ... in rounds/, else the legacy <v>.log."""
    rd = os.path.join(base_dir, "rounds")
    files = []
    if os.path.isdir(rd):
        pat = re.compile(r"^" + re.escape(v) + r"\.r(\d+)\.log$")
        found = []
        for f in os.listdir(rd):
            m = pat.match(f)
            if m:
                found.append((int(m.group(1)), os.path.join(rd, f)))
        files = [f for _, f in sorted(found)]
    if not files:
        legacy = os.path.join(base_dir, v + ".log")
        if os.path.isfile(legacy):
            files = [legacy]
    return files


def analyzeDir(base_dir, quiet=False):
    names = [v for v in VARIANTS if variantFiles(base_dir, v)]
    if not names:
        if not quiet:
            print("Error: no log files found in {}".format(base_dir))
        return False

    commit = ""
    try:
        with open(os.path.join(base_dir, "BASE_COMMIT")) as fd:
            commit = fd.read().strip()[:10]
    except Exception:
        pass

    results = {}
    rounds = {}
    for v in names:
        all1, all2, all3 = [], [], []
        rounds[v] = []
        for f in variantFiles(base_dir, v):
            with open(f, "r") as fd:
                datalist = fd.readlines()
            [d1, d2, d3] = preprocess(datalist)
            all1 += d1
            all2 += d2
            all3 += d3
            rounds[v].append([calc(d1)[0], calc(d2)[0]])
        results[v] = [calc(all1), calc(all2), calc(all3) if all3 != [] else None]

    orig_avg1 = results["original"][0][0] if "original" in results else None

    print("==== {}{} ====".format(base_dir, " (base: " + commit + ")" if commit else ""))
    displayHeader(orig_avg1 is not None)
    for v in names:
        q1, q2, q3 = results[v]
        print("**** {}:".format(label(v)))
        displaySingleBench(q1, q2, q3, orig_avg1)

    # Mean of each round.  If the rounds of one variant differ more than the
    # variants differ from each other, the machine drifted: do not trust it.
    if any(len(r) > 1 for r in rounds.values()):
        print()
        print("Per round (Query1 / Query2 [s], Overhead[%]):")
        for v in names:
            cells = []
            for q1, q2 in rounds[v]:
                cells.append("{:.2f}/{:.2f} ({:.2f})".format(q1, q2, 100 * (q2 - q1) / q1))
            print("  {:24s} {}".format(label(v), "  ".join(cells)))
    print()
    return True


if __name__ == "__main__":

    BASE_DIR = None

    if len(sys.argv) != 1 and len(sys.argv) != 2:
        print("Usage: python analyze.py [file|dir]")
        sys.exit(-1)

    if len(sys.argv) == 2:

        if os.path.isfile(sys.argv[1]):
            # file
            try:
                fd = open(sys.argv[1], "r")
                datalist = fd.readlines()
                fd.close()
            except Exception as e:
                print("Error: {}".format(e))
                sys.exit(1)

            [data1, data2, data3] = preprocess(datalist)
            [avg1, var1] = calc(data1)
            [avg2, var2] = calc(data2)
            displayHeader()
            if data3 != []:
                [avg3, var3] = calc(data3)
                displaySingleBench([avg1, var1], [avg2, var2], [avg3, var3])
            else:
                displaySingleBench([avg1, var1], [avg2, var2], None)

            sys.exit(0)

        elif os.path.isdir(sys.argv[1]):
            # dir
            BASE_DIR = sys.argv[1]

        else:
            print("Error: {} not found.".format(sys.argv[1]))
            sys.exit(1)

    if BASE_DIR is None:
        dirs = [d for d in ["pgsql-pg20", "pgsql", "pgsql-pg19"] if os.path.isdir(d)]
        if not dirs:
            print("Error: pgsql-pg20 not found.  Run: bash ./bench.sh benchmark")
            sys.exit(1)
    else:
        dirs = [BASE_DIR]

    ok = False
    for d in dirs:
        # directories without logs are skipped silently, unless asked for
        ok = analyzeDir(d, quiet=(BASE_DIR is None)) or ok
    if not ok and BASE_DIR is None:
        print("Error: no log files found.  Run: bash ./bench.sh benchmark")
    sys.exit(0 if ok else 1)
