---
title:  HDP Kerbreos 连接 HBase 登陆过期问题解析
tags: 云计算
categories: 云计算
date: 2019-03-04
comments: true
---

当前，我们是在 `HDP(3.0.0)` 的 `HBase (2.0.0)` 环境下，业务方想要访问我们的 HBase，需要通过认证才可访问，开始我们为每个业务方都提供了一个认证凭证，用户有效期为 1 天，用户续订期为7天，由于其中的一个业务方在访问我们的 HBase 时，是只进行一次登陆且为长期不断访问，所以我们对此用户设置的凭证有效时间有限，所以当该用户登陆后一天后，会报再次登陆时间超时，对此，我们为该用户进行了延长有效期和续订期的方案，以满足该用户可以持续不断的访问HBase。

<!-- more -->

## Kerberos

### 基本概念
[Kerberos](https://docs.hortonworks.com/HDPDocuments/Ambari-2.6.2.2/bk_ambari-security/content/kerberos_overview.html) 是一种计算机网络认证协议，它允许某实体在非安全网络环境下通信，向另一个实体以一种安全的方式证明自己的身份。主要是针对客户-服务器模型，并提供了一系列交互认证：即用户和服务器都能相互认证身份，Kerberos 简单来说就是一套完全控制机制，它有一个中心服务器（KDC），KDC 中有数据库，你可以往里添加各种“人 ”以及各种 “服务” 的 “身份证”。当某个人要访问某个服务时，他拿着自己的 ”身份证“ 联系 KDC 并告诉 KDC 他想要访问的服务，KDC 经过一系列验证步骤，最终依据验证结果允许/拒绝这个人访问此服务。


### 重要组成

- **KDC ：**密钥分发中心：认证服务器和票据服务器组成的“可信赖的第三方”

- **Client ：**需要使用kerbores服务的客户端

- **Service ：**提供具体服务的服务端


## HBase Authentication

### 场景说明

Kerberos 用户执行认证操作，会存在一个有效时间和一个续订时间，如果在有效时间内更新票据（不需重新认证），可以不断更新有效时间的时间区间，直至临近续订时间，此时，再执行更新票据操作，则无效。

### 原理

在 Kerberos 体系中存在 `Kerberos Server、Krbtgt、Krb5.conf、Kerberos Client、Kinit -l、Kinit -r ，Principal`  用户配置等多方面共同影响认证的有效时间。
其根据以上配置中的最小值进而影响有效时间

### 配置详解

#### Kerberos Server

在 `Kerberos Server` 服务器的 `/var/kerberos/krb5kdc/kdc.conf` 中的 `max-file`

```
max_life = 24h
```


#### Krbtgt

进入 kadmin

`kadmin.local`

#### 查看 KRBTGT 信息

```shell
getprinc krbtgt/DEVDIP.ORG
```

关注 `maximum ticket life` 最大票据有效时间
![krbtgt](https://ws2.sinaimg.cn/large/006tKfTcly1g0qjp045uwj30gu0anq39.jpg)

#### 用户（Principal）

```
kadmin.local     # 进入kadmin
getprinc dmp     # dmp 为 principal 名称
```

关注 `maximum ticket life`  票据最大有效时间
![dmp](https://ws2.sinaimg.cn/large/006tKfTcly1g0qjp4ay57j30eg0aljro.jpg)

#### Kerberos Client

在 `Kerberos client` 服务器 `/etc/krb5.conf` 文件下查看 `ticket_lifetime`

```
ticket_lifetime = 24h  # 凭证的有效时间
```


#### Krb5.conf

ticket 具有 lifetime（生命周期），超过设置的时间 ticket 就会过期，需要重新申请 renew

```
ticket_lifetime = 24h
```


#### Kinit -l

该命令是作为临时性修改有效时间，在 `kinit -l lifttime` 修改当前认证用户的有效时间，`kinit -l lifttime principal` 修改指定用户的有效时间 操作用户切换之后，就失效了。使用命令后不影响 KDC 库中相应用户的最大有效时间和最大续订时间

![kinit -l](https://ws3.sinaimg.cn/large/006tKfTcly1g0qjp7wc7gj30ft07aglt.jpg)

#### Kinit -r
该命令是作为临时性修改续订时间，在 `kinit -r lifttime` 修改当前用户的续订时间 `kinit -r lifttime principal` ，修改指定用户的续订时间 操作用户切换之后，就失效了。使用命令后不影响kdc库中相应用户的最大有效时间和最大续订时间

![kinit -r](https://ws3.sinaimg.cn/large/006tKfTcly1g0qjpc8kuyj30gs07tjrn.jpg)

## 影响因素

影响用户有效期 `ticket_lifetime` 和续订期 `renew_lifetime` 决定因素：

**Client 为 HDP 集群节点的影响因素**

1. `/var/kerberos/krb5kdc/kdc.conf` 中的 `max_life` 和 `max_renewable_life`
2. 各集群节点的 `/etc/krb5.conf` 中的 `ticket_lifetime` 和 `renew_lifetime`
3. `kadmin.local` 中内置的 `principal：krbtgt@REALM` 中的 `Maximum ticket life` 和 `Maximum renewable life`
4. `kadmin.local` 中用户自身的 `principal:Maximum ticket life` 和 `Maximum renewable life`
5. `kinit -l` 用户的有效时间和 `kinit -r` 用户的续订时间

**Client 为 `Windows/MAC OS` 上的 `MIT Kerberos` 的影响因素**

1. `/var/kerberos/krb5kdc/kdc.conf` 中的 `max_life` 和 `max_renewable_life`
2. Windows 上的 `C:\ProgramData\MIT\Kerberos5\krb5.ini` 中的 `ticket_lifetime` 和 `renew_lifetime`
3. `kadmin.local` 中内置的 `principal:krbtgt@REALM` 中的 `Maximum ticket life` 和 `Maximum renewable life`
4. `kadmin.local` 中用户自身的 `principal:Maximum ticket life` 和 `Maximum renewable life`

**Client 为 HDP 集群节点的影响因素**

1. `/var/kerberos/krb5kdc/kdc.conf` 中的 `max_life` 和 `max_renewable_life`
2. `kadmin.local` 中内置的 `principal:krbtgt@REALM` 中的 `Maximum ticket life` 和 `Maximum renewable life`
3. `kadmin.local` 中用户自身的 `principal:Maximum ticket life` 和 `Maximum renewable life`

### 问题
![](http://ww1.sinaimg.cn/large/70e059a2ly1g0qmfndajdj21pn0mmn5m.jpg)

### 解决方案

该用户通过 zk 方式连接原生 hbase 后，过一段时间发送请求会报上述错误，原因是：该用户在创建时设置的有效期为一天，续订期为 7 天，即在一天后该用户会账号信息会过期，需要重新认证，或这是在有效期内更新票据信息，但由于代码中不存在更新票据和重新认证的操作，故一天后会真正过期

1.更改 `/var/kerberos/krb5kdc/kdc.conf` 中的的 `max_life` 和 `max_renewable_life`

2.设置内置用户的 principal 的有效期和续订期

3.设置风控用户的 principal 的有效期和续订期

4.重启 kadmin 和 krb5kdc

#### 实现

```
< d:days,h:hours,m:minutes,s:seconds >
kadmin.local
modprinc -maxlife lifetime(d/h/m/s) krbtgt/REALM            ---修改有效期
modprinc -maxrenewlife lifetime（d/h/m/s）krbtgt/REALM      ---修改续订期
getprinc krbtgt/REALM                                       ---查看用户配置信息

modprinc -maxlife lifetime(d/h/m/s) fengkong                ---修改有效期
modprinc -maxrenewlife lifetime（d/h/m/s）  fengkong        ---修改续订期
getprinc   fengkong                                         ---查看用户配置信息

systemctl restart kadmin                                    ---重启
systemctl restart krb5kdc                                   ---重启
```

作者：何兰兰
