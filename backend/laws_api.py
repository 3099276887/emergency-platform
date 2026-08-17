# -*- coding: utf-8 -*-
"""法律文本查询接口（FastAPI Router）。

配合 frontend/index.html 的「安全法律」模块使用。前端通过以下两个接口，
从盒子的知识库源目录动态读取法律文本：

    GET /api/v1/laws            返回所有分类下的法律列表（标题 + 版本日期）
    GET /api/v1/laws/{law_id}   返回某部法律的完整结构化内容（含章节目录与条文）

目录约定（在 kb_source 下按分类建子目录，txt 放到对应子目录）：
    /data/SafeRAG/backend/data/kb_source/国/       -> 国家法律
    /data/SafeRAG/backend/data/kb_source/行政/     -> 行政法规
    /data/SafeRAG/backend/data/kb_source/地方/     -> 地方法规
每个子目录下直接放 *.txt（也兼容「国/txt/」这种多一层子目录）。

接入方式（在 SafeRAG 后端的 FastAPI 应用里）：
    from laws_api import router as laws_router
    app.include_router(laws_router, prefix="/api/v1")

如果你们的后端已经给 /api/v1 相关路由加了统一前缀，请相应调整 prefix。
"""
import re
from pathlib import Path

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["laws"])

# 盒子上的知识库源目录（txt 最终存放位置）
BASE_DIR = Path("/data/SafeRAG/backend/data/kb_source")

# 前端二级菜单分类键 -> kb_source 下的子目录名
CATEGORY_DIRS = {
    "national": "国",        # 国家法律
    "administrative": "行政",  # 行政法规
    "local": "地方",          # 地方法规
}

CH_RE = re.compile(r"^(第[一二三四五六七八九十百零〇]+章)")
ART_RE = re.compile(r"^(第[一二三四五六七八九十百零〇]+条)")


def _extract_version(stem: str) -> str:
    """从文件名末尾提取 _YYYYMMDD 版本日期。"""
    m = re.search(r"_(\d{8})$", stem)
    return m.group(1) if m else ""


def _is_toc_line(line: str) -> bool:
    """形如「目　　录」的目录标记行。"""
    return line.replace("　", "").replace(" ", "").strip() == "目录"


def _parse_law(text: str) -> dict:
    """把一部法律的纯文本解析为结构化数据。"""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return {"title": "", "date": "", "content": []}

    title = lines[0]

    i = 1
    date_parts = []
    while i < len(lines) and lines[i].startswith("（"):
        date_parts.append(lines[i])
        i += 1
    date = "\n".join(date_parts)

    toc_idx = None
    for j in range(i, len(lines)):
        if _is_toc_line(lines[j]):
            toc_idx = j
            break

    body_start = i
    if toc_idx is not None:
        seen = set()
        j = toc_idx + 1
        while j < len(lines):
            m = CH_RE.match(lines[j])
            if m:
                if m.group(1) in seen:
                    body_start = j
                    break
                seen.add(m.group(1))
            else:
                body_start = j
                break
            j += 1
        else:
            body_start = len(lines)

    content = []
    cur_article = None
    for line in lines[body_start:]:
        cm = CH_RE.match(line)
        if cm:
            cur_article = None
            content.append({"type": "chapter", "name": line})
            continue

        am = ART_RE.match(line)
        if am:
            num = am.group(1)
            rest = line[len(num):].strip("　 ")
            cur_article = {"type": "article", "name": num, "text": rest}
            content.append(cur_article)
            continue

        if cur_article is not None:
            cur_article["text"] += "\n" + line
        else:
            content.append({"type": "paragraph", "text": line})

    return {"title": title, "date": date, "content": content}


def _iter_law_files(category: str):
    """按分类遍历 kb_source 下的 txt 文件（兼容直接放或多一层子目录）。"""
    cat_dir = BASE_DIR / CATEGORY_DIRS[category]
    if cat_dir.is_dir():
        yield from sorted(cat_dir.rglob("*.txt"))


@router.get("/laws")
def list_laws():
    """返回 { 分类键: [{id, title, version}] }。"""
    result = {}
    for category in CATEGORY_DIRS:
        items = []
        for txt in _iter_law_files(category):
            try:
                text = txt.read_text(encoding="utf-8-sig")
                first = next((l.strip() for l in text.splitlines() if l.strip()), "")
            except Exception:
                first = ""
            items.append({
                "id": txt.stem,
                "title": first or txt.stem,
                "version": _extract_version(txt.stem),
            })
        result[category] = items
    return result


@router.get("/laws/{law_id}")
def get_law(law_id: str):
    """返回某部法律的完整结构化内容。"""
    for category in CATEGORY_DIRS:
        for txt in _iter_law_files(category):
            if txt.stem == law_id:
                text = txt.read_text(encoding="utf-8-sig")
                law = _parse_law(text)
                law["id"] = law_id
                law["version"] = _extract_version(txt.stem)
                law["category"] = category
                return law
    raise HTTPException(status_code=404, detail="法律未找到")
