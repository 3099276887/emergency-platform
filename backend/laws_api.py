# -*- coding: utf-8 -*-
"""法律文本查询接口（FastAPI Router）。

配合 frontend/index.html 的「安全法律」模块使用。前端通过以下两个接口，
从盒子的知识库源目录动态读取法律文本：

    GET /api/v1/laws            返回所有分类下的法律列表（标题 + 版本日期）
    GET /api/v1/laws/{law_id}   返回某部法律的完整结构化内容（含章节目录与条文）

目录约定（在 kb_source 下按分类建子目录，txt 放到对应子目录）：
    <KB_SOURCE_DIR>/国/       -> 国家法律
    <KB_SOURCE_DIR>/行政/     -> 行政法规
    <KB_SOURCE_DIR>/地方/     -> 地方法规
每个子目录下直接放 *.txt（也兼容「国/txt/」这种多一层子目录）。

可通过环境变量 KB_SOURCE_DIR 覆盖知识库源目录，缺省为：
    /data/SafeRAG/backend/data/kb_source

接入方式（在 SafeRAG 后端的 FastAPI 应用里）：
    from laws_api import router as laws_router
    app.include_router(laws_router, prefix="/api/v1")

如果你们的后端已经给 /api/v1 相关路由加了统一前缀，请相应调整 prefix。

法律 ID 约定：`{分类键}:{文件名stem}`，例如 `national:安全生产法_20210610`。
因不同分类下可能出现同名文件，ID 带分类前缀可避免歧义。
"""
import logging
import os
import re
from pathlib import Path

from fastapi import APIRouter, HTTPException

logger = logging.getLogger("laws_api")

router = APIRouter(tags=["laws"])

# 盒子上的知识库源目录（txt 最终存放位置），可用 KB_SOURCE_DIR 覆盖
BASE_DIR = Path(
    os.getenv("KB_SOURCE_DIR", "/data/SafeRAG/backend/data/kb_source")
).resolve()

# 前端二级菜单分类键 -> kb_source 下的子目录名
CATEGORY_DIRS = {
    "national": "国",        # 国家法律
    "administrative": "行政",  # 行政法规
    "local": "地方",          # 地方法规
}

CH_RE = re.compile(r"^(第[一二三四五六七八九十百零〇]+章)")
ART_RE = re.compile(r"^(第[一二三四五六七八九十百零〇]+条)")

# 文件索引缓存：{ 分类键: [Path...] }，配合目录签名按需重建，避免每次 rglob()
_index_cache = {}
_index_signature = {}


def _extract_version(stem: str) -> str:
    """从文件名末尾提取 _YYYYMMDD 版本日期。"""
    m = re.search(r"_(\d{8})$", stem)
    return m.group(1) if m else ""


def _is_toc_line(line: str) -> bool:
    """形如「目　　录」的目录标记行。"""
    return line.replace("　", "").replace(" ", "").strip() == "目录"


def _dir_signature(category: str):
    """返回分类目录的签名（mtime + size），用于判断是否需要重建索引。"""
    cat_dir = BASE_DIR / CATEGORY_DIRS[category]
    if not cat_dir.is_dir():
        return None
    st = cat_dir.stat()
    return (st.st_mtime_ns, st.st_size)


def _law_files(category: str):
    """按分类返回 txt 文件列表（带缓存；目录变化时自动重建）。"""
    cat_dir = BASE_DIR / CATEGORY_DIRS[category]

    if not cat_dir.is_dir():
        if _index_signature.get(category) is not None:
            logger.warning("分类目录不存在或未挂载: %s", cat_dir)
        _index_cache[category] = []
        _index_signature[category] = None
        return []

    sig = _dir_signature(category)
    if _index_signature.get(category) == sig:
        return _index_cache[category]

    # 重新扫描（兼容直接放或多一层子目录）
    files = sorted(cat_dir.rglob("*.txt"))
    _index_cache[category] = files
    _index_signature[category] = sig
    return files


def _parse_law(text: str) -> dict:
    """把一部法律的纯文本解析为结构化数据。

    正文起点判定：目录之后，优先以「首次重复出现的章标题」为准；
    若无重复章，则回退到目录之后的第一个「第X条」。这样可避免把
    目录里可能出现的「第X节」「第X条」误当作正文。
    """
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
        first_article_at = None
        j = toc_idx + 1
        while j < len(lines):
            line = lines[j]
            cm = CH_RE.match(line)
            am = ART_RE.match(line)

            if cm:
                name = cm.group(1)
                if name in seen:  # 章节标题第二次出现，即正文开始
                    body_start = j
                    break
                seen.add(name)
            elif am:
                # 目录里的「第X条」可能是目录项，先记下，作为回退起点
                if first_article_at is None:
                    first_article_at = j
            else:
                # 越过目录后遇到首个非章/条正文行；若已见章节则视为正文
                if seen:
                    body_start = j
                    break
            j += 1
        else:
            # 未出现重复章节：若目录里出现过「第X条」，从该处开始正文
            if first_article_at is not None:
                body_start = first_article_at
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


def _read_law(txt: Path, category: str) -> dict:
    """读取并解析一部法律；对编码/IO 错误给出明确报错。"""
    try:
        text = txt.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError:
        raise HTTPException(status_code=422, detail="法律文件不是 UTF-8 编码")
    except OSError:
        logger.exception("法律文件读取失败: %s", txt)
        raise HTTPException(status_code=500, detail="法律文件读取失败")

    law = _parse_law(text)
    law["id"] = f"{category}:{txt.stem}"
    law["version"] = _extract_version(txt.stem)
    law["category"] = category
    return law


@router.get("/laws")
def list_laws():
    """返回 { 分类键: [{id, title, version}] }。"""
    result = {}
    for category in CATEGORY_DIRS:
        items = []
        for txt in _law_files(category):
            try:
                text = txt.read_text(encoding="utf-8-sig")
                first = next((l.strip() for l in text.splitlines() if l.strip()), "")
            except Exception:
                logger.exception("读取法律文件失败: %s", txt)
                first = ""
            items.append({
                "id": f"{category}:{txt.stem}",
                "title": first or txt.stem,
                "version": _extract_version(txt.stem),
            })
        result[category] = items
    return result


@router.get("/laws/{law_id}")
def get_law(law_id: str):
    """返回某部法律的完整结构化内容。

    优先按「分类键:文件名」精确查找；若无分类前缀，则兼容旧 ID 跨分类扫描。
    """
    category, sep, stem = law_id.rpartition(":")
    if sep and category in CATEGORY_DIRS:
        for txt in _law_files(category):
            if txt.stem == stem:
                return _read_law(txt, category)
    else:
        # 兼容没有分类前缀的旧 ID
        for category in CATEGORY_DIRS:
            for txt in _law_files(category):
                if txt.stem == law_id:
                    return _read_law(txt, category)
    raise HTTPException(status_code=404, detail="法律未找到")
