---
title: Phoenix 二级索引探究
tags: [云计算]
categories: 云计算
date: 2019-03-04
comments: true
---

[HBASE](http://hbase.apache.org/) 是 `Google-Bigtable` 的开源实现，是一种构建在 HDFS 之上的分布式、面向列的存储系统，HBase 是一种非关系型数据库，也不支持 SQL ，因此我们使用了 [PHOENIX](http://phoenix.apache.org/) 。Phoenix 是构建在 HBase 上的一个 SQL 层，能让我们使用标准的 `JDBC API` 而不是 HBase 客户端 APIs 来创建表、插入数据和对 HBase 数据进行查询， 并且 Phoenix 还提供了二级索引技术，使我们可以在非 rowkey 的查询上速度更快。

<!-- more -->

版本信息:

- HDP:  3.0.0
- Hadoop:  3.0.1
- HBase: 2.0.0
- Phoenix: 5.0.0

## 二级索引

Phoenix 对 rowkey 进行排序，因此根据 rowkey 查询的时候，速度会非常的快。设计 rowkey 的时候，在保证散列、唯一的原则下，也通常将比较常用的查询条件设计到 rowkey 中，但是 rowkey 有一定的长度限制，也不可能把所有的查询条件都放到 rowkey 中，因而可以用二级索引。当为一张业务表创建索引后，索引字段在 HBase 中被冗余存储在 rowkey 的位置，因而可以通过索引实现范围扫描业务表，从而避免了全表扫描，大大提高查询速度。一张业务表默认最多可以创建 10 个索引，在 Phoenix 中会映射成 10 张索引表，如果超过 10 个索引，再去创建就会抛出异常 `java.sql.SQLException: ERROR 1047 (43A04): Too many indexes have already been created on the physical table. tableName=DMP.DMP_INDEX_TEST` 。在执行查询的时候执行计划会从所有的索引中选出一个最优的索引来使用，即每次查询只会用到一个索引。索引可以分为 `mutable` 和 `immutable` ，默认为 `mutable` ，可以通过在创建业务表的时候声明 `IMMUTABLE_ROWS=true` 来创建不可变表，这种不可变表创建的索引也是不可变的，它针对 `only written once and never updated` 场景，公司目前场景没涉及，不再详细讨论，以下都是针对 `mutable` 来做的探究。可变索引又可分为覆盖索引、本地索引、全局索引等，要想支持可变索引，需要在 `hbase-site.xml` 中增加配置。

### 配置 `hbase-site.xml` 以支持 `mutable` 索引

```xml
<property>
   <name>hbase.regionserver.wal.codec</name>
  <value>org.apache.hadoop.hbase.regionserver.wal.IndexedWALEditCodec</value>
</property>
```

### 本地索引

>Local indexing targets write heavy, space constrained use cases. Just like with global indexes, Phoenix will automatically select whether or not to use a local index at query-time. With local indexes, index data and table data co-reside on same server preventing any network overhead during writes. Local indexes can be used even when the query isn’t fully covered (i.e. Phoenix automatically retrieve the columns not in the index through point gets against the data table). Unlike global indexes, all local indexes of a table are stored in a single, separate shared table prior to 4.8.0 version. From 4.8.0 onwards we are storing all local index data in the separate shadow column families in the same data table. At read time when the local index is used, every region must be examined for the data as the exact region location of index data cannot be predetermined. Thus some overhead occurs at read-time.

>本地索引适用于写频繁、且存储空间有限的场景。和全局索引一样，Phoenix 会在查询时自动选择是否使用本地索引。使用本地索引，索引数据和表数据会写到同一个 `Region Servers` 上，从而避免了写入期间的网络开销。本地索引即使未完全覆盖业务表的所有字段，在查询的时候也会使用索引(Phoenix 会自动检索索引之外的字段，通过点查询业务表获得数据)。不同于全局索引，在4.8.0版本之前，业务表的所有本地索引都存储在一个单独的共享表中。在4.8.0版本之后，所有的本地索引数据都被存储在同一业务表的单独列族中。在使用本地索引的读取数据时，因为不能预先确定索引数据的确切区域位置，因而会对读取速度有一定的影响。

#### 本地索引的数据存储

创建 `dmp.dmp_index_test` 业务表

>create table dmp.dmp_index_test (id varchar not null primary key,name varchar, age varchar ,sex varchar, addr varchar);

插入数据

>upsert into dmp.dmp_index_test values ('id01','name01','age01','sex01','addr01');

创建本地索引

>create local index index_local_test_name on dmp.dmp_index_test (name);

查看 HBase 中数据

![](http://ww1.sinaimg.cn/large/e950dd69ly1g0qi3zu2gbj22090cgmyc.jpg)

>在 4.8 以后，本地索引的数据存储在同一业务表的一个特定的列族中，默认是 `L#0` 。某些情况使用 Phoenix 命令删除某个本地索引会超时，此时可以选择在 `hbase shell` 中执行 `alter 'DMP.DMP_INDEX_TEST', {NAME => 'L#0', METHOD => 'delete'}` 命令来强制删除索引，此过程需要先对业务表执行 `disable` 操作，操作完成再执行 `enable` 操作。

#### 本地索引是否命中

查看索引是否命中，可以使用 `explain` 来查看执行计划，以下是执行计划的一些解释：

- **CLIENT:** 表明操作在客户端执行还是服务端执行，客户端尽量返回少的数据。若为 `SERVER` 表示在服务端执行。

- **FILTER BY expression:** 返回和过滤条件匹配的结果。

- **FULL SCAN OVER tableName:** 表明全表扫描某张业务表。

- **RANGE SCAN OVER tableName [ … ]**  表明代表范围扫描某张表，括号内代表 rowkey 的开始和结束。

- **ROUND ROBIN**  无 `ORDER BY` 操作时， `ROUND ROBIN` 代表最大化客户端的并行化。

- **x-CHUNK:**  执行此操作的线程数。

- **PARALLEL x-WAY:** 表明合并多少并行的扫描。

- **EST_BYTES_READ:** 执行查询时预计扫描的总字节数。

- **EST_ROWS_READ:**  执行查询时预计扫描多少行。

- **EST_INFO_TS:** 收集查询信息的 `epoch time`

本地索引查询字段未在索引列，也会使用索引

![](http://ww1.sinaimg.cn/large/e950dd69ly1g0qi6nke5bj22di09lt9n.jpg)

创建覆盖索引

>create local index index_local_include_test_one on dmp.dmp_index_test (age) include (sex);

![](http://ww1.sinaimg.cn/large/e950dd69ly1g0qi93t508j22c7095js9.jpg)

我们此时去查看 HBase ，可以看到在索引列族 `L#0` 冗余存储了 `include` 的字段

![](http://ww1.sinaimg.cn/large/e950dd69ly1g0qi9ilg1kj224o0hgmzc.jpg)

覆盖索引可以避免查询条件未在索引列而不使用索引的情况，只有查询条件未在索引列，也没在覆盖列，才会进行全表扫描

![](http://ww1.sinaimg.cn/large/e950dd69gy1g0qiadx8ahj22cy0jzacc.jpg)

可以创建组合索引来解决多个条件查询索引命中问题，组合索引的第一个字段必须要在查询条件中

![](http://ww1.sinaimg.cn/large/e950dd69gy1g0qib1xhm3j22sk0um0wo.jpg)

#### 小结

本地索引不支持分桶表，HBase 中不会有单独的表维护，在 Phoenix 中会有索引表映射出来。执行写操作时候，数据存储在本地，不会进行额外的网络IO；执行读操作的时候，根据索引条件范围扫描，实现快速查询；若空间允许，可以创建覆盖索引，避免查询条件多变导致索引未命中。适用场景是写频繁。

### 全局索引

>Global indexing targets read heavy uses cases. With global indexes, all the performance penalties for indexes occur at write time. We intercept the data table updates on write (DELETE, UPSERT VALUES and UPSERT SELECT), build the index update and then sent any necessary updates to all interested index tables. At read time, Phoenix will select the index table to use that will produce the fastest query time and directly scan it just like any other HBase table. By default, unless hinted, an index will not be used for a query that references a column that isn’t part of the index.

>全局索引适用于读频繁的场景。对于全局索引，所有性能消耗都发生在写入时，所有对业务表的更新操作(DELETE, UPSERT VALUES and UPSERT SELECT)，会引起索引的更新，而索引是分布在不同的节点上的，跨节点的数据传输带来了较大的性能消耗。在读数据的时候 Phoenix 会选择最快的索引，把它当作一般的 HBase 表来扫描，而不去扫描业务表。在默认情况下，没有指定强制使用索引，如果查询的字段没有在索引列的话，这种情况下索引不会被使用。

#### 全局索引的数据存储

创建 `dmp.dmp_index_test` 业务表

>create table dmp.dmp_index_test (id varchar not null primary key,name varchar, age varchar ,sex varchar, addr varchar);

插入数据
>upsert into dmp.dmp_index_test values ('id01','name01','age01','sex01','addr01');

创建全局索引

- create index index_global_test_name on dmp.dmp_index_test (name);

- create index index_global_test_include_name on dmp.dmp_index_test (name) include (age);

查看 HBase 中数据

![](http://ww1.sinaimg.cn/large/e950dd69gy1g0qibloyqmj220h0emt9u.jpg)

>可以看到，对于全局索引来说，在 HBase 中会有一张单独的表来维护索引，因此在查询命中索引的时候，是根据查询条件来范围扫描过滤索引表，而不会去扫描业务数据表。

#### 全局索引是否命中

全局索引查询字段未创建索引，但是使用 `include` 关键词存储了此字段的 value 值，那么此时索引可以命中。

![](http://ww1.sinaimg.cn/large/e950dd69ly1g0qj6sf26nj22lz0iqwgq.jpg)

全局索引查询字段未创建索引，也未使用 `include` 关键词覆盖此字段，可以通过 `/* + INDEX(TableName MyIndexName)*/` 命令强制使用索引，不过要明确经过查询条件过滤后，返回结果集不大，否则会造成全表扫描。

![](http://ww1.sinaimg.cn/large/e950dd69ly1g0qih0h39nj22qd132dle.jpg)

使用多条件查询，可以创建组合索引，组合索引的第一个字段必须是查询条件，否则可能会导致全表扫描。

>create index index_global_test_mutil on dmp.dmp_index_test (name,age,sex) include (addr);

![](http://ww1.sinaimg.cn/large/e950dd69ly1g0qiinyf62j22rf0tradw.jpg)

#### 小结

全局索引支持分桶表，默认会使用和业务表一样的分桶规则，HBase 中有单独且唯一的索引表维护，因此在写入操作的时候，各个 Region Servers 之间可能会有网络IO，这样比较消耗性能，因此适用于多读少写的场景。全局索引在查询的时候，其实是去直接查索引表，若查询字段没有创建索引又想使用索引，可以使用 `include` 关键词覆盖此字段，将此字段的 value 值冗余存储，会额外占用空间，但可以保证命中索引，或者使用 `/* + INDEX(TableName MyIndexName)*/` 命令强制使用索引，适用于返回结果集较少的情况，避免全表扫描。

### 异步索引

>By default, when an index is created, it is populated synchronously during the CREATE INDEX call. This may not be feasible depending on the current size of the data table. As of 4.5, initially population of an index may be done asynchronously by including the ASYNC keyword in the index creation DDL statement.The map reduce job that populates the index table must be kicked off separately through the HBase command line

>默认情况下，创建索引时，会在 CREATE INDEX 执行期间同步填充索引数据。对于小表，这种方式可以实现，如果对于一张很大的表，那么此时创建索引就会超时。从4.5开始，可以通过在创建索引时使用 `ASYNC` 关键字，异步完成索引数据的填充。创建完成后查看索引的状态是 `BUILDING` ，必须通过 HBase 命令行单独启动 `map reduce` 任务来完成索引数据填充的工作，MR 任务执行成功之后，查看索引状态变为 `ACTIVE`，这样索引才能正常使用。

#### 创建异步索引

在我们实际业务场景中，很多情况都是会根据需求去为某张业务表定制一个索引，而此时业务表的数据量非常大，创建同步索引肯定会超时，此时可以通过创建异步索引来解决这个问题。

>create index index_global_test_async on dmp.dmp_index_test (name) include (age) ASYNC;

#### 启动 MR 任务，完成数据填充与索引激活

在执行 HBase 命令之前，确保当前用户对 HBase 以及所操作的表有权限，一般需要 `su - hbase` 切换到 `hbase` 用户，再执行相应的命令。在我们的环境中，因为启用了 [Kerberos](https://web.mit.edu/kerberos/) ，所以在执行命令之前，首先需要执行 `kinit` 命令，完成用户的认证，然后再执行 HBase 命令，提交 MR 任务。如果环境中对 YARN 也做了权限管理，那么需要通过授权工具将提交 MR 任务的权限赋予 `hbase` 用户。

Kerberos 用户认证

>kinit -kt /path/hbase.headless.keytab hbase-name@DOMAIN.ORG

使用 HBase 命令启动 MR 任务

>HADOOP_CLASSPATH="/etc/hbase/conf" hadoop jar /path/phoenix/phoenix-client.jar org.apache.phoenix.mapreduce.index.IndexTool --schema DMP --data-table DMP_INDEX_TEST --index-table INDEX_GLOBAL_TEST_ASYNC --output-path /hbase-backup2

MR 任务完成之后，查看索引表的状态已经变为 `ACTIVE` ，此时索引表是启用状态。

创建异步索引，未执行 MR 任务

![](http://ww1.sinaimg.cn/large/e950dd69ly1g0qij344syj227v0axab1.jpg)

MR 任务执行成功，索引状态为 `ACTIVE`

![](http://ww1.sinaimg.cn/large/e950dd69ly1g0qijkkifaj22h208b753.jpg)

#### Phoenix IndexTool 的坑

Phoenix 官网上，启动 MR 任务的命令为
```shell
$ {HBASE_HOME} / bin / hbase org.apache.phoenix.mapreduce.index.IndexTool 
  --schema MY_SCHEMA --data-table MY_TABLE --index-table ASYNC_IDX 
  --output-path ASYNC_IDX_HFILES
```

这个命令使用 `phoenix-server.jar` ，在这个包中存在 `commons-cli` 的依赖冲突，因此用这个命令启动 MR 任务，会产生报错：`Exception in thread "main" java.lang.NoClassDefFoundError: org/apache/commons/cli/DefaultParser` ，因此需要在启动 MR 任务的时候，使用 `$ hadoop jar $PHOENIX_HOME/phoenix-*client.jar org.apache.phoenix.mapreduce.index.IndexTool` 命令，指定使用 `phoenix-client.jar` ，任务得以成功提交并运行。这个问题在 [PHOENIX-4880](https://issues.apache.org/jira/browse/PHOENIX-4880) 和 [HBASE-20201](https://issues.apache.org/jira/browse/HBASE-20201) 也有更加详细的说明，可以参考 Issue Tracking 中的描述解决问题。

### 总结

Phoenix 提供多种索引技术，`Covered Indexes` 冗余存储 value 值，使用空间换速度，节省查询返回结果的时间，`Local Indexes` 较低的写入性能损耗，适用写频繁的场景，`Global Indexes` 单独维护一张索引表，直接通过扫描索引表返回结果集，适用读频繁的场景。本文针对几种常用的索引进行了探究，以及如何查看是否命中索引，当然 Phoenix 还有比较复杂的 join 的情况，也遵循单表索引的基本规则。Phoenix 在查询模式较为灵活的场景，不管是索引个数的限制，还是索引机制的影响，都会略显不足，对大量 scan 的类型的 OLAP 查询也不太友好。Phoenix 的索引也有自己适合的场景以及优缺点，根据实际业务场景及查询要求，合理的选择和设计索引，Phoenix 都能很好的满足。

### Q&A

- 异步创建本地索引，且使用自定义的 `schema` ，使用 `IndexTool` 报错 `Error: java.lang.RuntimeException: org.apache.phoenix.schema.TableNotFoundException: ERROR 1012 (42M03)`

  使用自定义 `schema` 创建异步索引，目前只能创建全局索引。使用  `default schema` 可以支持本地索引和全局索引。具体解决方案，社区还没有回答。

- 查看执行计划索引命中了，为何执行时间那么长？

  索引命中和执行时间长短没有绝对的正比关系，是由实际的查询条件决定的，有时索引命中了，但是查询条件并没有过滤到大部分数据，若此时再去范围扫描业务表的话，就会耗时很长，甚至比全表扫描还慢，所以设计索引的时候要确保使用索引真的可以过滤掉大部分数据。
  
- 为何使用分桶表？

  Phoenix 为了避免 HBase 的热点写入，导致服务器负载不均衡，因而提供了自定义分桶的方式，即 `salt row keys with a prefix` ，就是在 rowkey 上使用加盐密钥的前缀，避免 rowkey 不散列，导致热点问题，可以在创建业务表的时候声明 `SALT_BUCKETS=x` 属性来对表进行分桶，那么在表创建之后，就会有 x 个 Table Regions 散列在不同的 Region Server 上，x 的值一般是1~256.

### 参考

- https://mp.weixin.qq.com/s/7bg1hu7LI9m7KbXAt-SN2Q
- https://blog.csdn.net/gaoshui87/article/details/52381927
- https://blog.csdn.net/maomaosi2009/article/details/45619679
- https://phoenix.apache.org/index.html
- https://sematext.com/blog/hbasewd-avoid-regionserver-hotspotting-despite-writing-records-with-sequential-keys/

**作者：** 张延召