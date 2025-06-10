#!/bin/bash
# filepath: /Users/apple/Desktop/Programming/Personal-Site/zxsheather.github.io/deploy.sh

# 显示当前操作状态
echo "开始构建网站..."

# 构建站点
JEKYLL_ENV=production bundle exec jekyll build

# 检查构建是否成功
if [ $? -ne 0 ]; then
  echo "构建失败，取消部署"
  exit 1
fi

echo "构建成功，准备部署..."

# 部署到gh-pages分支
cd _site
git init
git add .
git commit -m "网站更新: $(date +'%Y-%m-%d %H:%M:%S')"
git branch -M gh-pages
git remote add origin git@github.com:zxsheather/zxsheather.github.io.git

echo "正在部署到GitHub Pages..."
git push -f origin gh-pages

# 返回项目根目录
cd ..
# 清理临时git仓库
rm -rf _site/.git

echo "✅ 部署完成!"