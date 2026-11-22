# Benchmark for fast EXPLAIN ANALYZE 2

This repository stores the tools and results for benchmarking Fast EXPLAIN ANALYZE, as described in my blog post:
+ [Fast EXPLAIN ANALYZE 2](http://www.interdb.jp/blog/pgsql/fast_explain_analyze2/)

This version benchmarks two row-count-only instrumentation patches against PostgreSQL 20 (`master`):

| Option         | Patch                                                        | Description |
|----------------|--------------------------------------------------------------|-------------|
| `original`     | (none)                                                       | Unpatched `master`: 9b5d4e3 |
| `alt-wrapper`  | `patches/v1-0001-alt-rowcount-only-instr-wrapper.patch`       | Row counting in a lightweight `ExecProcNodeInstrRows()` wrapper |
| `only-in-node` | `patches/v1-0001-rowcount-only-instr-in-ExecProcNode.patch`   | Row counting inlined in `ExecProcNode()` (no wrapper call) |

Both patches use the lightweight path only when timing, buffer and WAL usage are all off, e.g. `EXPLAIN (ANALYZE TRUE, TIMING FALSE, BUFFERS FALSE)`, which is what `batches/batch.sql` runs.

The base is the tip of `origin/REL_19_STABLE` at the time `setup` is run. To pin a specific commit, set `COMMIT` in `bench.sh`.

## Requirements

1. PostgreSQL development environment (gcc, make, flex, bison, etc.)
2. git
3. Python3

## Setup

```
$ git clone https://github.com/s-hironobu/fast_explain_analyze.git
$ cd fast_explain_analyze
$ bash ./bench.sh setup
```

#### Remark:
This shell script does not contain any `rm` commands. It only uses `cd`, `echo`, `git`, `make`, and `patch`, as well as `pg_ctl`, `createdb`, and `psql`.


## Benckmark

Run all benchmarks at once with the following command:

```
$ bash ./bench.sh benchmark
```

If you want to run them step-by-step, specify the option:

```
$ bash ./bench.sh benchmark [original|alt-wrapper|only-in-node]
```

The results are written to `pgsql/original.log`, `pgsql/alt-wrapper.log` and `pgsql/only-in-node.log`.

After the benchmark is complete, you can use analyze.py to aggregate and display the results:

```
$ python ./analyze.py
$ python analyze.py
	Duration[s] (var. [s^2]) 	Overhead[%]
-----------------------------------------------------
**** original:
Query1	120.1261 	(0.0219)	N/A
Query2	149.8707 	(0.1024)	24.76
**** alt-wrapper:
Query1	120.0420 	(0.0459)	N/A
Query2	127.5671 	(0.0612)	6.27
**** only-in-node:
Query1	121.8334 	(0.0332)	N/A
Query2	124.1280 	(0.0428)	1.88
```

Query1 is the plain `SELECT`; Query2 is `EXPLAIN (ANALYZE TRUE, TIMING FALSE, BUFFERS FALSE)` of the same query. Overhead is Query2 relative to Query1.

If you want to analyze only specific results, specify the data file:

```
$ python3 ./analyze.py ./pgsql/alt-wrapper.log
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
- 22 Nov 2026: Version 2.0 released. Rebased on PostgreSQL 20 (`master`); benchmarks the `alt-wrapper` and `only-in-node` patches.
- 10 Dec 2025: Version 1.0 released.
