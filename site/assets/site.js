// Wasla website: fills in the plan prices (set by the platform admin in the
// app) and the Android download details (written by the deploy).
(function () {
  var SUPABASE_URL = 'https://qbefpiuglhsgcgwsaocn.supabase.co';
  // The publishable key is meant to be public: it only reaches what the
  // database lets visitors see, which is the plan list.
  var SUPABASE_KEY = 'sb_publishable_f0s_ZGnr-fOq-OPCG1-bsA_isXiRQma';

  var ar = document.documentElement.lang === 'ar';
  var root = document.body.getAttribute('data-root') || './';

  var text = ar
    ? {
        names: { Free: 'المجانية', Basic: 'الأساسية', Business: 'الأعمال', Enterprise: 'المؤسسات' },
        free: 'مجانًا',
        onRequest: 'حسب الطلب',
        perMonth: 'لكل مساحة عمل شهريًا',
        forever: 'بلا مدة',
        members: function (n) {
          return n === null ? 'أعضاء بلا حد'
            : n === 1 ? 'عضو واحد' : n === 2 ? 'عضوان'
            : n <= 10 ? n + ' أعضاء' : n + ' عضوًا';
        },
        storage: function (n) {
          return n === null ? 'تخزين بلا حد' : n + ' جيجابايت للملفات';
        },
        everything: 'كل المزايا: المحادثات والمشاريع والمهام والمتابعة',
        version: function (v) {
          return 'الإصدار ' + v.version + ' · ' + mb(v.bytes) + ' ميجابايت · ' + day(v.date);
        }
      }
    : {
        names: {},
        free: 'Free',
        onRequest: 'On request',
        perMonth: 'per workspace a month',
        forever: 'no time limit',
        members: function (n) {
          return n === null ? 'Unlimited members' : n === 1 ? '1 member' : n + ' members';
        },
        storage: function (n) {
          return n === null ? 'Unlimited storage' : n + ' GB for files';
        },
        everything: 'Every feature: chats, projects, tasks and follow-up',
        version: function (v) {
          return 'Version ' + v.version + ' · ' + mb(v.bytes) + ' MB · ' + day(v.date);
        }
      };

  function mb(bytes) {
    return (bytes / 1048576).toFixed(0);
  }

  function day(iso) {
    try {
      return new Date(iso + 'T12:00:00Z').toLocaleDateString(ar ? 'ar-EG-u-nu-latn' : 'en-GB', {
        day: 'numeric', month: 'long', year: 'numeric'
      });
    } catch (e) {
      return iso;
    }
  }

  function money(n) {
    var whole = Math.round(n) === n;
    var s = n.toLocaleString('en-US', {
      minimumFractionDigits: whole ? 0 : 2,
      maximumFractionDigits: 2
    });
    return ar ? s + ' دولار' : '$' + s;
  }

  function el(tag, cls, content) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (content !== undefined) e.textContent = content;
    return e;
  }

  function showPlans(plans) {
    var box = document.getElementById('plans');
    if (!box || !plans || !plans.length) return;
    box.textContent = '';
    var paid = plans.filter(function (p) { return p.id !== 'free' && p.price_usd > 0; });
    var featured = paid.length > 1 ? paid[1].id : paid.length ? paid[0].id : null;
    plans.forEach(function (p) {
      var card = el('div', 'card plan' + (p.id === featured ? ' featured' : ''));
      card.appendChild(el('h3', null, text.names[p.name] || p.name));
      var price = el('div', 'price');
      if (p.id === 'free') {
        price.textContent = text.free;
        card.appendChild(price);
        card.appendChild(el('div', 'meta', text.forever));
      } else if (p.price_usd > 0) {
        price.textContent = money(Number(p.price_usd));
        card.appendChild(price);
        card.appendChild(el('div', 'meta', text.perMonth));
      } else {
        price.textContent = text.onRequest;
        card.appendChild(price);
        card.appendChild(el('div', 'meta', ' '));
      }
      var list = el('ul');
      list.appendChild(el('li', null, text.members(p.max_members)));
      list.appendChild(el('li', null, text.storage(p.storage_gb)));
      list.appendChild(el('li', null, text.everything));
      card.appendChild(list);
      box.appendChild(card);
    });
    var note = document.getElementById('plans-note');
    if (note) note.hidden = false;
  }

  function loadPlans() {
    if (!window.fetch) return;
    fetch(SUPABASE_URL + '/rest/v1/rpc/public_plans', {
      method: 'POST',
      headers: {
        apikey: SUPABASE_KEY,
        'Content-Type': 'application/json'
      },
      body: '{}'
    })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(showPlans)
      .catch(function () {});
  }

  function loadVersion() {
    if (!window.fetch) return;
    fetch(root + 'download/version.json', { cache: 'no-cache' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (v) {
        if (!v || !v.version) return;
        document.querySelectorAll('[data-apk]').forEach(function (a) {
          a.setAttribute('href', root + 'download/wasla.apk');
          a.removeAttribute('aria-disabled');
          a.removeAttribute('tabindex');
          var label = a.querySelector('[data-label]');
          if (label) label.textContent = a.getAttribute('data-ready');
        });
        var meta = document.getElementById('apk-meta');
        if (meta) meta.textContent = text.version(v);
      })
      .catch(function () {});
  }

  var year = document.getElementById('year');
  if (year) year.textContent = new Date().getFullYear();
  loadPlans();
  loadVersion();
})();
