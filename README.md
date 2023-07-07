
# 1.环境配置：
这里推荐下一个轻量级RPC库，需要安装zeromq和cppzmq的依赖，按照[cppzmq](https://github.com/zeromq/cppzmq#build-instructions)中所说的先安装libzmq，后安装cppzmq。
【注】编译安装cppzmq的时候，可能会遇到如下问题：https://github.com/zeromq/cppzmq/issues/591

# 2.编译
编译：
```
sh build.sh
```

# 3.运行

运行配置服务器：
```
./masterServer
```
访问配置服务器：
```
./masterClient
```
运行kvserver
```
./server 
```
运行客户端：
```
./client
```
【注】这里使用同一个服务器的不同端口模拟多个不同的服务器。


# 4.C++分布式键值存储系统（shardKv）介绍

shardKv就是要实现如下系统：
![](https://img2023.cnblogs.com/blog/1617829/202306/1617829-20230609171213712-916291764.png)

client从shardctrler中获取服务配置，从而得知当前client请求应该发送给哪个KVServer，然后向对应KVServer发送请求。
KVServer从shardctrler中获取服务配置，从而得知当前KVServer中应该处理哪些请求。








## 4.1 实现shardctrler





### 简介与configs


**简介：**在代码中，Group表示一个Leader-Followers集群，Gid为它的标识；Shard表示所有请求的一个子集，也就是说一个shard可能代表多个请求；Config表示一个划分方案。本实验中，所有请求分为NShards = 10份，Controller Server给测试程序提供四个接口：
* Join：为某个Group添加节点，或添加Group。
* Leave：移除某个Group。
* Move：某个Shard分配给某个Group处理。注意不需要负载均衡，负载均衡会破坏Move的语义。
* Query：上面三个操作都会改变当前Config，代码中定义了一个Config数组，上面三个操作都会Config数组，Query用于查询Config，如果query为-1或者大于configs长度的都返回最新的config，否则返回对应的config。

Controller Server也会组成一个集群，使用Raft做容灾处理，因此，Controller Server和KVServer是一样的结构。只不过是从Get、Put、Append变成了Join、Leave、Move、Query，因此直接把Lab3A的代码复制过来，再稍加改动就OK了。
【注】Controller Server在有些人写的代码中称为master、shardctrler

**configs：**configs存储了所有的config版本，每一次进行Join或Leave或Move都会基于当前config追加一个新的config到configs中，之所以要保存所有的config，主要是为了测试程序检查。下面是一个config的结构：
```
class Config{
public:
    int configNum;      // config number
    vector<int> shards; // shard -> gid 
    unordered_map<int, vector<string>> groups;  // gid -> servers[]
};
```
- configNum就是版本编号；
- Shards记录当前方案，即每个shard由哪个group负责处理。这个分配方案应该是均衡的，所以每一次config的变化都要重新分配，使Shards平均。
shards中的每个元素代表一个分片，初始是[0,0,0,0,0,0,0,0,0,0]；groups中存储着每个gid对应的哪些server。每个shard都会分配给某个组，当存在多个组时，不能将所有shard都分配给某一个组，要让所有的组都分配到差不多的shard，即做好负载均衡。
**举个例子，**shards初始为[0,0,0,0,0,0,0,0,0,0]，那么Join了Group1 -> servers[a, b, c] 之后，整个系统就有1个Group了，那么，shards就会变成[1,1,1,1,1,1,1,1,1,1]，如果JoinGroup2 -> servers[e, f, g]之后，整个系统就有2个groups了，那么，10个shards就需要尽量平均分配给两个Groups，也就是[1,1,1,1,1,2,2,2,2,2]
- 【问题】每个请求都会对应一个Shard，每个Shard都会对应一个group，那为什么不直接将请求对应到group？
答：每个请求肯定是要对应一个group，那么这个请求和group是如何对应的，本项目中就是使用Shard进行对应。



参考：
[链接1](https://blog.csdn.net/weixin_45938441/article/details/125386091)
[链接2](https://blog.csdn.net/Joshmo/article/details/111955297)
[链接3（写得最好）](https://juejin.cn/post/7031561918439489550)



### 代码解读



ShardMaster.StartShardMaster()中开启了RPCserver和applyLoop，RPCserver提供了Join、Leave、Query和Move服务。ShardMaster提供服务的过程：
- client向ShardMaster中的Join/Leave/Query/Move发送请求，ShardMaster中的Join/Leave/Query/Move将请求放入m_raft.start()中，然后阻塞等待。
- 当底层的m_raft将请求复制到大多数节点中时会提交。
- m_raft.applyLogLoop()会检测到提交但是未应用到状态机上的日志（即请求），然后使用信号量通知上层的ShardMaster.applyLoop()**应用这些日志到状态机中**。
- ShardMaster.applyLoop()执行完毕会通知ShardMaster中的Join/Leave/Query/Move的执行结果，并解除阻塞，然后给返回client执行是否成功的结果。

“应用到状态机”执行的操作：
- Join/Leave/Move会修改configs和进行负载均衡操作。
- Query用于查询Config，如果query为-1或者大于configs长度的都返回最新的config，否则返回对应的config。

**负载均衡：**
- 在做负载均衡前，需要给未分配到group的shards分配group：找出负载最小的组，将一个shards分配给该组。然后再次找出负载最小的组，将一个shards分配给该组。直到所有的shards都分配到了组。
- 负载均衡：负载均衡的结果是所有gid的shards数量相同或者最大最小只差1。所以使用小顶堆和大顶堆保存所有组，每次将负载最多组中的shards弹出到负载最小的组中，直到满足所有gid的shards数量相同或者最大最小只差1。


**其他简单的负载均衡：**每一次写请求后都需要修改Shards保证所有group负责的shard数量最大和最小之差不超过1，这里先收集所有group负责的shard数量，然后进行排序。具体为：先算出平均每个group应该负责多少个shard，多的拿出来，少的加进去。为了保证每个Controller Server动作一致，所以shard数量相等时，按照gid排序。




## 4.2 client的设计



client如何将特定的key定向到正确的分片以及负责该分片的集群
* 通过key2shard函数，将string类型的key映射到特定shard，
* 通过当前config中的shards得到该shard对应集群的GID
* 通过当前config中的groups得到该GID对应集群内所有server的名字
* 通过make_end函数，将server名字对应到其RPC端口
* 遍历所有server的端口，直到确认是leader并成功受理请求



## 4.3 KVServer的设计


KVServer中的shardClerk从shardctrler中获取服务配置信息。配置信息里面说明当前KVServer集群需要服务的分片，这就涉及到了不同groups间的通信，比如配置信息中要求集群A服务分片2，此时集群A就可能需要从别的集群中拉取分片2的信息。groups间的通信主要有：
- 数据迁移，拉取新数据给自己。由于config更新，有新的shard由当前集群负责，需要从上一个config中获取负责该分片的集群信息，并从该集群中获取分片内容。每个集群中使用raft将搬迁的数据同步到集群中的服务器上。
- 垃圾回收，需要告知送出数据方的group自己已成功接收，让其清理对应分片的数据。



**Kvserver的集群间的通过过程举例：**若有3个集群G1,G2,G3，若config为[1, 1, 1, 2, 2, 2, 3, 3, 3, 3]，即group1的集群负责分片1，2，3，group2的集群负责4，5，6，group3的集群负责7，8，9，10。
每个集群的leader会定期查询配置，若配置变化，需要集群间通信，若变为[1, 1, 1, 2, 2, 2, 3, 3, 4, 4],即加入了新的集群group4，则
- 1、集群4要向原先负责分片shard9，10的集群group3发送RPC，拉取对应分片的数据库数据以及一些状态信息
- 2、集群4收到集群3的reply后，向集群3发送清理分片9，10的RPC，必须要接收方确认收到数据才能让发送方删除数据






## 4.3.1 3个守护线程







**raft实现一致性的过程：**
- 将操作放入raft.start()，操作会被包装成日志。start中并不执行向其他节点同步此日志的操作，向其他节点同步日志的操作在leader的processEntriesLoop中执行。
- processEntriesLoop中会周期性地创建n-1个sendAppendEntries线程，n-1个sendAppendEntries线程向n-1个其他节点发送leader中的日志。如果leader的日志已经全部同步给了某个节点，此时也会使用sendAppendEntries发送空的日志，即心跳。当raft将日志复制到半数以上的节点中时会提交。
- applyLogLoop发现存在已提交但是未应用到状态机的日志，则将日志一个一个的放入raft->m_msgs中，并通过信号量通知上层的applyLoop将日志应用到状态机上。

可以发现上述实现一致性的过程中，底层的raft没有执行日志中具体的命令，而只是将日志同步到各个节点中，具体命令的执行放在了上层的applyLoop中。所以要实现不同功能的集群，只需要修改applyLoop中的处理逻辑，底层的raft不需要修改。



**数据成员：**
- toOutShards：需要送出去的分片。configNUm -> shard -> (key, value)，就是将分片对应的kv从数据库中送出并删除。
- comeInShards：需要拉取的分片。shard -> configNum。
- m_AvailableShards：当前可用的分片。

**updateConfigLoop：**updateConfigLoop定时从shardctrler中获取最新配置，然后将获取到的最新的config包装成operation放入m_raft.start()实现集群的一致性。applyLoop中的updateComeInAndOutShrads实现具体的配置更新：
- 从m_AvailableShards中移除本group不负责的shard，将需要拉取的分片放入comeInShards中。
- 将需要送出去的分片和分片对应在数据库中的kv放在toOutShards中，并将数据库对应的数据删除。

**pullShardLoop：**
- pullShardLoop定时查看comeInShards是否不为空，并为comeInShards中的每个分片都开启一个doPullShard线程，并在doPullShard线程中使用rpc调用远程的shardMigration函数。
【注】comeInShards中的每个分片都开启一个线程的原因是rpc调用拉去分片数据的过程中可能会阻塞，所以给comeInShards中的每个分片都创建一个线程用于拉去分片对应的kv数据。
- 远程的shardMigration函数将toOutShards中的kv数据返回给doPullShard。
- doPullShard将获取到的kv用于更新数据库，即更新数据库的操作放入m_raft.start()实现集群的一致性。applyLoop中的updateDataBaseWithMigrateReply用于实现具体的数据库更新。
- 数据库更新完毕后，更新comeInShards、m_AvailableShards，以及garbages。garbages中存储着新获取到的分片。

**garbagesCollectLoop：**
- garbagesCollectLoop定时查看garbages是否不为空，并为garbages中的每个分片都开启一个doGarbage线程，并在doGarbage线程中使用rpc调用远程的garbagesCollect函数通知远程将这些分片删除。
- 远程的garbagesCollect函数将分片删除操作放入m_raft.start()实现集群的一致性，garbagesCollect会阻塞等待垃圾清理成功，并回应doGarbage。
- 远程的applyLoop中的clearToOutData用于清理toOutShards中已经送出的分片。然后garbagesCollect会收到垃圾清理成功的回应。

可以发现，updateConfigLoop和pullShardLoop都是更新自己，garbagesCollectLoop是通知其他服务器去更新。




