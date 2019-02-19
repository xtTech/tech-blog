#!/bin/sh
git add -A
m = `date +%Y.%m.%d.%k:%M`
git commit -m $m
git push origin master
if [ $? -eq 0 ]
then
  echo '====success push==== \n'
else
  echo '====failure push==== \n'
fi