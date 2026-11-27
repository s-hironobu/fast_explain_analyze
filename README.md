# Benchmark for fast EXPLAIN ANALYZE 2

This repository stores the tools and results for benchmarking Fast EXPLAIN ANALYZE, as described in my blog post:
+ [Fast EXPLAIN ANALYZE 2](http://www.interdb.jp/blog/pgsql/fast_explain_analyze2/)

This version benchmarks the `lite-rowcount` patch against unpatched PostgreSQL 20devel (`9ebc9a458c3`).

| Option         | Patch                                  | Description |
|----------------|----------------------------------------|-------------|
| `original`     | (none)                                 | Unpatched PostgreSQL 20devel |
| `lite-rowcount`| `patches/pg20-lite-rowcount.patch`      | Row counting in a lightweight `ExecProcNodeInstrRows()` wrapper |

Experimental variant (run with `benchmark all` or by name):

| Option             | Patch                                    | Description |
|--------------------|------------------------------------------|-------------|
| `feather-rowcount` | `patches/pg20-feather-rowcount.patch`     | Row counting inlined in `ExecProcNode()` (no wrapper call) |

The patches use the lightweight path only when timing, buffer and WAL usage are all off, e.g. `EXPLAIN (ANALYZE TRUE, TIMING FALSE, BUFFERS FALSE)`, which is what `batches/batch.sql` runs.

All variants are built on the same commit, `COMMIT` in `bench.sh`.

## Requirements

1. PostgreSQL development environment (gcc, make, flex, bison, etc.)
2. git
3. Python3

## Setup

```
$ git clone https://github.com/s-hironobu/fast_explain_analyze.git
$ cd fast_explain_analyze
$ bash ./bench.sh setup                # -> pgsql-pg20/
```

#### Remark:
This shell script does not contain any `rm` commands. It only uses `cd`, `echo`, `git`, `make`, `mkdir`, `tr`, and `patch`, as well as `pg_ctl`, `createdb`, and `psql`.


## Benchmark

```
$ bash ./bench.sh benchmark                  # original, lite-rowcount
$ bash ./bench.sh benchmark all              # + feather-rowcount (experimental)
$ bash ./bench.sh benchmark lite-rowcount    # only the given variant
```

### How the measurement is organized

A benchmark that builds one variant, measures it, and then builds the next one cannot separate a variant's cost from the drift of the machine (thermal throttling of a fanless laptop, background jobs, ...): the differences we look for are 1-3%.
The tool therefore works as follows:

1. Every variant is built once into its own directory, `<pgsql>/variants/<variant>/`. A variant that is already built is reused (`REBUILD=1` builds it again).
2. All variants run on the same data directory (`<pgsql>/data`). The patches do not change the on-disk format. `VACUUM ANALYZE` is run once before the first measurement, so that every variant sees the same heap.
3. The measurement is repeated for `ROUNDS` rounds (default 3), and the **order of the variants is rotated in every round**, so that no variant is always first or last.

```
$ ROUNDS=5 bash ./bench.sh benchmark
```

The log of each run is written to `<pgsql>/rounds/<variant>.r<N>.log`, and the commit actually built is recorded in `BASE_COMMIT` in the same directory.

After the benchmark is complete, you can use analyze.py to aggregate and display the results.
Without arguments it shows the results found in `pgsql-pg20/`. Variants without logs are not shown; the experimental ones appear only if you ran them:

```
$ python3 ./analyze.py
==== pgsql-pg20 (base: 9ebc9a458c) ====
	Duration[s] (var. [s^2]) 	Overhead[%]	vs. original Query1[%]
---------------------------------------------------------------------
**** original:
Query1	121.4873 	(0.4225)	N/A	0.00
Query2	151.9161 	(0.6283)	25.05	25.05
**** lite-rowcount:
Query1	121.2020 	(0.4064)	N/A	-0.23
Query2	129.2084 	(0.4697)	6.61	6.36

Per round (Query1 / Query2 [s], Overhead[%]):
  original        121.70/152.20 (25.06)  121.92/152.48 (25.06)  120.84/151.07 (25.02)
  lite-rowcount   121.76/129.82 (6.62)  121.24/129.26 (6.61)  120.61/128.55 (6.59)
```

All rounds of a variant are pooled for the table.
The `Per round` lines show the mean of each round: if the rounds of one variant differ from each other by as much as the variants do, the machine drifted and the result should not be trusted. Run the benchmark again, with more rounds.


Query1 is the plain `SELECT`; Query2 is `EXPLAIN (ANALYZE TRUE, TIMING FALSE, BUFFERS FALSE)` of the same query.
`Overhead` is Query2 relative to the same variant's Query1; `vs. original Query1` is relative to the Query1 of `original` on the same base, so it also includes any slowdown of the plain `SELECT`.

If you want to analyze only one directory or one file, specify it:

```
$ python3 ./analyze.py ./pgsql-pg20
$ python3 ./analyze.py ./pgsql-pg20/rounds/lite-rowcount.r1.log
```

## Others

### Running a custom benchmark
If you want to run a different benchmark query, perform the following steps:

1. Define the necessary tables in testdb.
2. Update the QUERY variable in batches/create_batches.py to your desired query.

```
QUERY = "SELECT count(*) FROM test1 AS a, test2 AS b, test3 AS c WHERE a.id = c.id;"
```

3. Run create_batches.py:

```
$ cd batches
$ python3 create_batches.py
```

## Change Log
- 27 Nov 2026: renamed the patches (`alt-wrapper` -> `lite-rowcount`, `only-in-node` -> `feather-rowcount`).
- 24 Nov 2026: Version 2.1: the benchmark now builds each variant once and measures them in rotated rounds, instead of one block per variant; the per-round means are shown.
- 22 Nov 2026: Version 2.0 released. Rebased on PostgreSQL 20 (`master`); benchmarks the `alt-wrapper` and `only-in-node` patches.
- 10 Dec 2025: Version 1.0 released.
