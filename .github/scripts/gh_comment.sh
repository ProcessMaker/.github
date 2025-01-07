#! /bin/sh
if [ -z "$INSTANCE_URL" ]; then
  echo "No instance URL"
  exit 0
fi

project=$1
pull_id=$2

if [ $pull_id -eq 0 ]; then
  exit 0
fi

comment_url=https://api.github.com/repos/ProcessMaker/$project/issues/$pull_id/comments

curl $comment_url \
  -s -H "Authorization: token $GITHUB_COMMENT" \
  -X POST -d "{\"body\": \"QA server K8S was successfully deployed $INSTANCE_URL\"}"