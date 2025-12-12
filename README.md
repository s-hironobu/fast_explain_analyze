# Benchmark for fast EXPLAIN ANALYZE

This repository stores the tools and results for benchmarking Fast EXPLAIN ANALYZE, as described in my blog post:
+ [Fast EXPLAIN ANALYZE](http://www.interdb.jp/blog/pgsql/fast_explain_analyze/)

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
$ bash ./bench.sh benchmark [phase0|phase1|phase2|phase3]
```

After the benchmark is complete, you can use analyze.py to aggregate and display the results:

```
$ python ./analyze.py 
	Duration[s] (var. [s^2]) 	Overhead[%]
-----------------------------------------------------
**** Original:
Query1	120.7846 	(0.1260)	N/A
Query2	152.9188 	(0.3539)	26.60
**** Phase 1:
Query1	120.7209 	(0.0822)	N/A
Query2	130.6013 	(0.0257)	8.18
**** Phase 2:
Query1	121.3559 	(0.0007)	N/A
Query2	125.5515 	(0.0039)	3.46
**** Phase 3:
Query1	122.1207 	(0.1115)	N/A
Query2	122.7696 	(0.1403)	0.53
```

If you want to analyze only specific results, specify the data file:

```
$ python3 ./analyze.py ./pgsql/phase1.log
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
- 10 Dec 2025: Version 1.0 released.
