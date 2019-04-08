---
title: Webpack4+Babel7+ES6兼容IE8
tags: webpack、babel、es6、ie8
categories: 前端
date: 2019-04-03
comments: true
---

前阵子重构了一个挺有意思的项目，是一个基于浏览器环境的数据采集sdk。公司各个产品的前端页面中都嵌入了这个sdk，用于采集用户的行为数据，上传到公司的大数据平台，为后续的运营决策分析提供数据支撑。
<!-- more -->

笔者接手这个项目的时候，前任开发者已经把功能都写差不多了。唯一需要做的就是做下模块化拆分和代码规范，以便后续的开发维护。模块化拆分用webpack，代码规范用eslint。既然要重构，那就顺手用es6重写吧。callback也不要了，全换成promise，async、await也用起来，反正怎么爽怎么写。

问PM浏览器最低兼容到哪个版本，PM说兼容公司各个产品所兼容的最低版本就行。和公司各个产品的前端负责人沟通后发现，居然有兼容IE8的，真是我了个fk。

google了一下Webpack+Babel+ES6兼容IE8，果然坑很多。试了好几篇博客给出的方案，都跑不通。也没怎么研究具体哪里有问题，因为那些解决方案里面的webpack和babel都是旧版的，跑通了也不高兴用。笔者分析了那些博客中提出的几个关键性问题，然后参考webpack和babel最新的官方文档，总结出一套最新的Webpack4+Babel7+ES6兼容IE8的方案。

# ES6兼容IE8需要解决四个问题
## 语法支持
IE浏览器不支持ES6的语法，只在IE10、IE11中支持了部分ES6的API，所以在IE浏览器中使用ES6需要把ES6的代码编译成ES5才能执行。方法也很简单，就是用```babel-loader```。这部分没什么坑，所以我也就不细说了。给个网站，大家可以自行查看ES5、ES6在各浏览器版本中的支持情况

https://kangax.github.io/compat-table/es6/

## ES3保留关键字
如果在IE8下通过```object.propertyName```的方式使用ES3中的保留关键字（比如```default、class、catch```），就会报错
```
SCRIPT1048: 缺少标识符
```

webpack有一款loader插件```es3ify-loader```专门用来处理ES3的兼容问题。这个插件的作用就是把这些保留字给你加上引号，使用字符串的形式引用。
```js
// 编译前
function(t) { return t.default; }

// 编译后
function(t) { return t["default"]; }
```

然而，笔者亲身实践后发现，```UglifyJS```本来就已经提供了对IE浏览器的支持，不需要额外引入```es3ify-loader```。webpack默认的```UglifyJS```配置不支持ie8，需要手动配下。
```js
{
  mode: 'production',
  optimization: {
    minimizer: [
      new UglifyJsPlugin({
        uglifyOptions: {
          ie8: true
        }
      })
    ]
  }
}
```

## 执行环境
解决了前面两个问题只能保证语法上不报错，但使用ES6中的API（比如```Promise```）还是会报错。另外，IE8对ES5的API支持也很差，只支持了少量的API，有些API还只是支持部分功能（比如```Object.defineProperty```）。所以，要在IE8中完美运行ES6的代码，不仅需要填充ES6的API，还要填充ES5的API。

babel为此提供了两种解决方案：[@babel/polyfill](https://babeljs.io/docs/en/babel-polyfill)、[@babel/runtime](https://babeljs.io/docs/en/babel-runtime)。具体使用方法官方文档已经写的很详细了，笔者就不赘述了。想了解两者之间的差别的同学可以看下大搜车墨白同学的文章，[babel-polyfill VS babel-runtime](https://juejin.im/post/5a96859a6fb9a063523e2591)

这里纠正墨白同学文中的一个错误，就是```@babel/polyfill```现在已经支持按需加载，准确的说也不能算是错误，因为墨白同学在写这篇文章的时候还不支持按需加载。具体方法我就不细说了，文档里都有，配置下[browserlist](https://github.com/browserslist/browserslist)和```@babel/preset-env```的```useBuiltsIns```属性就可以了。

我只说下我在实际开发过程中碰到的坑。

虽然```@babel/polyfill、@babel/runtime```都支持按需加载，但都只能识别出业务代码中使用到的缺失的API，如果第三方库有用到这些缺失的API，babel不能识别出来，自然也就不能填充进来。比如```regenerator-runtime```中用到的```Object.create```和```Array.prototype.forEach```。

## 模块化加载
笔者原来是想用ES6的模块化加载方案，因为这样可以利用webpack的[tree shaking](https://webpack.docschina.org/guides/tree-shaking/)，移除冗余代码，使打包出来的文件体积更小。但在IE8下测试发现Object.defineProperty会报错```'Accessors not supported!'```。报错代码如下

```js
if ('get' in Attributes || 'set' in Attributes) throw TypeError('Accessors not supported!');
```
我用[@babel/plugin-transform-modules-commonjs](https://www.babeljs.cn/docs/babel-plugin-transform-modules-commonjs)转成commonjs加载就可以把这个坑绕过去，但同时也意味着放弃了```tree shaking```。

# 总结
## package.json
```js
{
  "devDependencies": {
    "@babel/core": "^7.2.2",
    "@babel/plugin-transform-runtime": "^7.2.0",
    "@babel/preset-env": "^7.1.0",
    "@babel/runtime": "^7.3.4",
    "babel-loader": "^8.0.4",
    "uglifyjs-webpack-plugin": "^2.0.1",
    "webpack": "^4.20.2",
    "webpack-cli": "^3.1.2",
    "webpack-dev-server": "^3.1.9",
    "webpack-merge": "^4.1.4"
  }
}
```

## webpack配置
```js
{
  module: {
    rules: [
      {
        test: /\.js$/,
        exclude: /(node_modules|bower_components)/,
        use: {
          loader: 'babel-loader',
          options: {
            presets: [
              '@babel/preset-env'
            ],
            plugins: [
              [
                '@babel/plugin-transform-runtime'
              ],
              [
                '@babel/plugin-transform-modules-commonjs'
              ]
            ]
          }
        }
      }
    ]
  },
  optimization: {
    minimizer: [
      new UglifyJsPlugin({
        sourceMap: true,
        uglifyOptions: {
          ie8: true,
        }
      })
    ]
  }
}
```

## 入口文件按需引入缺失的API
```js
require('core-js/fn/object/define-property')
require('core-js/fn/object/create')
require('core-js/fn/object/assign')
require('core-js/fn/array/for-each')
require('core-js/fn/array/index-of')
require('core-js/fn/function/bind')
require('core-js/fn/promise')
```

最后附上文章开头提到的sdk源码，笔者已将公司业务相关代码去除，将通用部分开源。https://github.com/xtTech/dc-sdk-js