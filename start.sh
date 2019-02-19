#!/bin/sh
# hexo generate
# if [ $? -eq 0 ]
# then
#   echo '====success hexo generate==== \n'
# else
#   echo '====failure hexo generate==== \n'
# fi

# hexo d
# if [ $? -eq 0 ]
# then
#   echo '====success hexo deloy==== \n'
# else
#   echo '====failure hexo deloy==== \n'
# fi

# hexo b
# if [ $? -eq 0 ]
# then
#   echo '====success hexo backup==== \n'
# else
#   echo '====failure hexo backup==== \n'
# fi
`git add .`
`m = date +%Y.%m.%d.%k:%M`
`git commit -m $m`
`git push origin master`
if [ $? -eq 0 ]
then
  echo '====success push==== \n'
else
  echo '====failure push==== \n'
fi