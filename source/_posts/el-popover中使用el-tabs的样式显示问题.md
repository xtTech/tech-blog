---
title: el-popover中使用el-tabs的样式显示问题
tags: [前端,UI组件]
categories: 前端
date: 2019-03-29
comments: true
---

## 前言
笔者最近在写一个管理后台的项目，技术栈选的是vue+element-ui。有一个需求是在一个表格的操作栏中点击按钮展示出价记录和入场券记录，如下图所示
![](https://drafish.github.io/static-files/imgs/20190329100057.jpg)
<!-- more -->

产品的原意应该是让我用dialog对话框来做，但笔者觉得对话框太重了，想用一个更加轻量的组件popover。看了下官方文档，官方已经给出了popover中嵌套table的demo，ctrl+c、ctrl+v，美滋滋。自己只需要在官方demo的基础上再加个el-tabs组件就可以了。代码写完了一跑，发现el-tabs组件的tab-bar没显示出来。下图左边是实际展示效果，右边是正常应该展示的效果。
![](https://drafish.github.io/static-files/imgs/20190329110202.jpg)

## 问题分析
问题原因有两点：
* el-popover利用display属性来控制popover框的显示和隐藏
* el-tabs中tab-bar的属性通过计算tab的物理宽高获得

这两个组件单独使用不会有问题。但组合使用时，当popover框处于隐藏状态时，el-tabs中tab的物理宽高都为0。进而导致tab-bar的属性计算异常。

## 解决方案
简单介绍下解决思路。要解决这个问题，主要就是要解决如何在隐藏状态下获取tab的物理宽高。说到这里，有经验的同学可能已经想到了用visibility:hidden来隐藏组件。但这个方式有一个问题，被隐藏的组件会影响文档布局。所以再加一个position:absolute，使组件脱离文档流。

总结下解决方案，就是将el-popover的隐藏方式从display:none改成visibility:hidden;position:absolute。

笔者已将这个解决方案提了个[pull request](https://github.com/ElemeFE/element/pull/14891)给element，希望能被merge。

但笔者眼前的问题还是没有解决，element官方接不接受我的pr还不一定呢。就算将来能接受，那现在一时半会儿也用不上。得有一个临时解决方案填这个坑。

## 临时解决方案
### 方案一
将el-popover组件的源码复制出来，写一个自定义的组件，并修改隐藏方式。在项目中引入自定义组件来替代el-popover。

### 方案二
利用el-popover的show事件和after-enter事件，在显示触发时将el-tabs绑定的model置空，在显示完成时为model重新赋值。原理是通过改变el-tabs的model值，触发tab-bar重新计算style属性。

笔者项目中用的就是方案二，因为方案二只要加两行代码就能搞定，方案一要多写好多代码。