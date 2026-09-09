/* 统一翻页组件 —— 复用，避免各页面重复实现

用法:
  renderPager(container, {
    total: 记录总数,
    page: 当前页(从1起),
    pageSize: 每页条数,
    info: 可选, 用于显示"共 X 条，第 Y / Z 页"的元素,
    onJump: function(page){ ... }  // 翻到 page 时的回调
  })

自带内联样式，不依赖宿主页 CSS，任何页面接入即用。
功能: 上一页 | 页码(省略号可点击跳页) | 下一页 | 跳至[页]跳转
*/
(function(){
  /* 生成页码列表，around 为当前页前后显示页数；过长时以 "..." 表示省略 */
  function buildPages(n, cur){
    var around = 2, out = [];
    if(n <= 7){ for(var i = 1; i <= n; i++) out.push(i); return out; }
    out.push(1);
    var s = Math.max(2, cur - around), e = Math.min(n - 1, cur + around);
    if(s > 2) out.push("...");
    for(var j = s; j <= e; j++) out.push(j);
    if(e < n - 1) out.push("...");
    out.push(n);
    return out;
  }

  var BTN      = 'border:1px solid #cbd7de;border-radius:4px;background:#fff;color:#233;cursor:pointer;font-size:13px;padding:6px 10px;min-width:36px';
  var BTN_ACT  = 'background:#2563eb;color:#fff;border-color:#2563eb';
  var BTN_DIS  = 'opacity:.4;cursor:not-allowed';

  window.renderPager = function(container, opts){
    opts = opts || {};
    var total = +opts.total || 0;
    var page  = +opts.page || 1;
    var size  = +opts.pageSize || 20;
    var info  = opts.info || null;
    var onJump = opts.onJump || function(){};
    var n = Math.ceil(total / size) || 1;

    if(info) info.textContent = "共 " + total + " 条，第 " + page + " / " + n + " 页";

    if(n <= 1){ container.innerHTML = ""; return; }

    var pages = buildPages(n, page);
    var h = '<div style="display:flex;align-items:center;justify-content:center;gap:6px;flex-wrap:wrap">';

    // 上一页
    h += '<button type="button" data-p="' + (page-1) + '"' +
         (page <= 1 ? ' disabled style="' + BTN + BTN_DIS + '"' : ' style="' + BTN + '"') + '>上一页</button>';

    // 页码（省略号可点击跳页）
    pages.forEach(function(p){
      if(p === "..."){
        h += '<button type="button" data-jump style="' + BTN + ';background:none;border:none" title="点击跳页">…</button>';
      }else if(p === page){
        h += '<button type="button" data-p="' + p + '" style="' + BTN + BTN_ACT + '">' + p + '</button>';
      }else{
        h += '<button type="button" data-p="' + p + '" style="' + BTN + '">' + p + '</button>';
      }
    });

    // 下一页
    h += '<button type="button" data-p="' + (page+1) + '"' +
         (page >= n ? ' disabled style="' + BTN + BTN_DIS + '"' : ' style="' + BTN + '"') + '>下一页</button>';

    // 跳页
    h += '<span style="display:inline-flex;align-items:center;gap:6px">跳至 ' +
         '<input data-jumpin type="number" min="1" max="' + n + '" value="' + page + '" style="width:60px;padding:6px 8px;border:1px solid #cbd7de;border-radius:4px;font:inherit"> 页 ' +
         '<button type="button" data-jumpgo style="' + BTN + '">跳转</button></span>';

    h += '</div>';
    container.innerHTML = h;

    function go(p){
      p = parseInt(p, 10);
      if(p > 0 && p <= n && p !== page) onJump(p);
    }
    var input = container.querySelector('[data-jumpin]');
    function doJump(){ go(input.value); }
    container.querySelector('[data-jumpgo]').onclick = doJump;
    input.addEventListener('keydown', function(e){
      if(e.key === 'Enter' || e.key === 'Escape') doJump();
    });
    container.querySelectorAll('[data-p]').forEach(function(b){
      b.onclick = function(){ if(!b.disabled) go(b.getAttribute('data-p')); };
    });
    container.querySelectorAll('[data-jump]').forEach(function(b){
      b.onclick = function(){ input.focus(); input.select(); };
    });
  };
})();