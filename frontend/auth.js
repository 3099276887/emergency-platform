/* SafeRAG 前端统一鉴权脚本（index / admin / law_detail / data_detail 四个页面共用）
 *
 * - 从 localStorage 读取/写入 JWT
 * - 页面加载时：未登录则重定向到 login.html（保留原地址用于登录后跳回）
 * - 拦截 window.fetch：自动附加 Authorization: Bearer 头
 * - 收到 401 时：清除凭证并重定向到登录页
 * - 提供 window.authUrl()：给 <a href> 类 GET 下载链接追加 ?token=
 */
(function(){
  var KEY = "sferag_jwt_token";
  var LOGIN_PAGE = "login.html";

  function currentUrl(){
    return location.pathname + location.search + location.hash;
  }

  function getToken(){
    try { return localStorage.getItem(KEY); } catch(e){ return null; }
  }

  function setToken(t){
    try {
      if(t) localStorage.setItem(KEY, t);
      else localStorage.removeItem(KEY);
    } catch(e){ /* ignore */ }
  }

  function logout(){
    setToken(null);
    window.__sferagToken = null;
  }

  function toLogin(){
    if(location.pathname.indexOf(LOGIN_PAGE) >= 0) return; // 已在登录页，避免死循环
    if(location.protocol === "file:"){
      alert("请通过 HTTP/HTTPS 访问本平台（当前为 file:// 协议）");
      return;
    }
    location.replace(LOGIN_PAGE + "?redirect=" + encodeURIComponent(currentUrl()));
  }

  // 供登录页 / 其它页面使用
  window.__sferagToken = getToken();
  window.setAuthToken = setToken;
  window.getAuthToken = getToken;
  window.logoutAuth = logout;

  // 下载链接（<a href> / window.open 类 GET）需要把 token 放进 query，浏览器才能带上
  window.authUrl = function(url){
    var t = getToken();
    if(!t) return url;
    var sep = url.indexOf("?") >= 0 ? "&" : "?";
    return url + sep + "token=" + encodeURIComponent(t);
  };

  // 未登录：直接跳转登录页
  if(!window.__sferagToken){
    toLogin();
  }

  // 拦截 fetch：自动附加 Authorization 头；401 统一登出并跳转；403 弹出无权限提示
  if(window.fetch){
    var _origFetch = window.fetch.bind(window);
    window.fetch = function(input, init){
      init = init || {};
      var headers = new Headers(init.headers || {});
      if(!headers.has("Authorization")){
        var t = getToken();
        if(t) headers.set("Authorization", "Bearer " + t);
      }
      init.headers = headers;
      return _origFetch(input, init).then(function(resp){
        if(resp.status === 401 && location.pathname.indexOf(LOGIN_PAGE) < 0){
          logout();
          toLogin();
        }
        if(resp.status === 403){
          resp.json().then(function(data){
            var msg = data.detail || data.message || "您没有该操作的权限，请检查账号角色";
            alert("权限不足：" + msg);
          }).catch(function(){
            alert("权限不足：您的账号不拥有该操作权限");
          });
        }
        return resp;
      });
    };
  }
})();