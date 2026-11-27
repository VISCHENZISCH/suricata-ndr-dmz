(function () {
  fetch("/api/me", { credentials: "same-origin" })
    .then(function (r) {
      if (!r.ok) throw new Error("non connecté");
      return r.json();
    })
    .then(function (user) {
      // ── Connecté : mettre à jour la navbar ──
      var nav = document.querySelector(".navbar");
      if (!nav) return;

      // Supprimer les liens Connexion / Inscription
      nav.querySelectorAll('a[href="login.html"], a[href="register.html"]').forEach(function (a) {
        a.remove();
      });

      // Ajouter l'email + bouton déconnexion
      var span = document.createElement("span");
      span.className = "nav-user";
      span.textContent = user.email;
      nav.appendChild(span);

      var btn = document.createElement("a");
      btn.href = "#";
      btn.className = "nav-logout";
      btn.textContent = "Déconnexion";
      btn.onclick = function (e) {
        e.preventDefault();
        fetch("/api/logout", { method: "POST", credentials: "same-origin" })
          .then(function () { window.location.href = "/login.html"; });
      };
      nav.appendChild(btn);
    })
    .catch(function () {
      // ── Non connecté : protéger le dashboard ──
      if (window.location.pathname.indexOf("dashboard") !== -1) {
        window.location.href = "/login.html";
      }
    });

  // ── Intercepter les formulaires login / register pour afficher les erreurs ──
  var authForm = document.querySelector('form[action="/api/login"], form[action="/api/register"]');
  if (authForm) {
    authForm.addEventListener("submit", function (e) {
      e.preventDefault();

      var errorBox = document.getElementById("auth-error");
      if (!errorBox) {
        errorBox = document.createElement("div");
        errorBox.id = "auth-error";
        errorBox.className = "note warning";
        errorBox.style.display = "none";
        authForm.parentNode.insertBefore(errorBox, authForm);
      }
      errorBox.style.display = "none";

      fetch(authForm.action, {
        method: "POST",
        credentials: "same-origin",
        body: new URLSearchParams(new FormData(authForm)),
      })
        .then(function (r) {
          if (r.ok) {
            window.location.href = r.redirected ? r.url : "/dashboard.html";
            return null;
          }
          return r.json().catch(function () {
            return { detail: "Erreur serveur (" + r.status + ")." };
          });
        })
        .then(function (data) {
          if (!data) return;
          var msg = typeof data.detail === "string"
            ? data.detail
            : "Une erreur est survenue. Vérifiez vos informations.";
          errorBox.innerHTML = "<p></p>";
          errorBox.querySelector("p").textContent = msg;
          errorBox.style.display = "block";
        })
        .catch(function () {
          errorBox.innerHTML = "<p>Impossible de contacter le serveur.</p>";
          errorBox.style.display = "block";
        });
    });
  }

  // ── Boutons menu / sidebar (remplace les onclick inline bloqués par la CSP) ──
  var menuBtn = document.querySelector(".menu-toggle");
  if (menuBtn) {
    menuBtn.addEventListener("click", function () {
      var nav = document.querySelector(".navbar");
      if (nav) nav.classList.toggle("open");
    });
  }
  var sidebarBtn = document.querySelector(".sidebar-toggle");
  if (sidebarBtn) {
    sidebarBtn.addEventListener("click", function () {
      var sidebar = sidebarBtn.closest(".sidebar");
      if (sidebar) sidebar.classList.remove("open");
    });
  }
})();
