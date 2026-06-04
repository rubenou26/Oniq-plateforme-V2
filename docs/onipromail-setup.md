# OniProMail — Mise en route (envoi + accompagnement domaine client)

Ce document explique **ce que toi (Ruben / Melvyn) dois déployer et configurer** pour
que l'envoi d'emails fonctionne, et pour qu'un client puisse « passer chez nous »
avec son propre domaine.

> Le code est livré et versionné dans le repo. Ce qui reste = de la configuration
> sur Supabase, Resend et le DNS — des opérations que je ne peux pas faire à ta place
> (elles demandent l'accès à tes dashboards et tes secrets).

---

## 1. Ce qui a été livré (code)

| Élément | Chemin | Rôle |
|---|---|---|
| Edge Function **send-reply** | `supabase/functions/send-reply/index.ts` | Envoie les emails (nouveau message OniProMail + réponse ONIASSIST) via Resend |
| Edge Function **domain-setup** | `supabase/functions/domain-setup/index.ts` | Crée/vérifie le domaine d'un client dans Resend, renvoie les DNS à coller |
| Relais parent | `index.html` (`onipromail-send-email`, `onipromail-domain-setup`) | Fait le pont iframe OniProMail ↔ Edge Functions |
| Client OniProMail | blob dans `index.html` | Wizard domaine réel + fiabilité d'envoi + séparation Gmail |

Côté client, en plus du wizard, ces bugs d'envoi sont corrigés :
- bouton « Envoyer » **désactivé pendant l'envoi** (plus de double-clic = double mail) ;
- **timeout 30 s** : si le serveur ne répond pas, l'UI se débloque et affiche l'erreur ;
- **panneau d'erreur persistant** dans la fenêtre de rédaction (affiche le vrai message
  Resend, ex. « The domain is not verified » → tu sais quoi corriger) ;
- liste des mails : séparation nette façon Gmail (point doré non-lu, fond teinté, hover).

---

## 2. Prérequis Resend (une fois)

1. Compte sur https://resend.com → **API Keys** → crée une clé.
2. **Vérifie le domaine d'envoi `oniq.online`** dans Resend (Domains → Add Domain) :
   ajoute les enregistrements DKIM/SPF/DMARC qu'il te donne dans ton DNS Cloudflare.
   Tant que `oniq.online` n'est pas « Verified », **aucun envoi depuis `@oniq.online`
   ne partira** (c'est très probablement la cause du « même eux ne peuvent pas envoyer »).

---

## 3. Déploiement des Edge Functions

Avec la CLI Supabase (`npm i -g supabase`, puis `supabase login`) :

```bash
# à la racine du repo (où se trouve le dossier supabase/)
supabase link --project-ref kxdxxhepewziazfnfnkq

# le secret utilisé par les deux fonctions
supabase secrets set RESEND_API_KEY=re_xxxxxxxxxxxxxxxxx

# déploiement
supabase functions deploy send-reply
supabase functions deploy domain-setup
```

> Alternative sans CLI : Dashboard Supabase → Edge Functions → New function →
> colle le contenu de chaque `index.ts` → Deploy. Et Settings → Edge Functions →
> Secrets → ajoute `RESEND_API_KEY`.

`SUPABASE_URL` et `SUPABASE_SERVICE_ROLE_KEY` sont injectés automatiquement par Supabase
(utilisés par send-reply en mode réponse pour relire la table `emails`).

Après déploiement, dans OniProMail → rédiger un message → **Envoyer** doit fonctionner
(à condition que le domaine de l'expéditeur soit vérifié dans Resend).

---

## 4. Accompagnement « le client a son domaine » (scénario B)

Dans OniProMail → **Paramètres → Domaine personnalisé** :

1. Le client saisit son domaine (ex. `maconnerie-dupont.fr`).
2. Il clique **« Configurer / vérifier mon domaine »** → `domain-setup` crée le domaine
   dans Resend et renvoie la **liste exacte des enregistrements DNS** (SPF, DKIM, DMARC).
3. Le client colle ces enregistrements chez son registrar (clic = copie).
4. Il reclique **« Configurer / vérifier »** → quand Resend voit les DNS, le statut passe
   à **Vérifié ✓** et il peut **envoyer** depuis `contact@maconnerie-dupont.fr`.

### ⚠️ Réception (inbound) — à finaliser

L'**envoi** sur un domaine client marche dès qu'il est vérifié dans Resend (étape ci-dessus).
La **réception** d'emails entrants sur ce domaine nécessite, en plus, un routage entrant
qui écrit dans la table `emails` :

- Aujourd'hui c'est **Cloudflare Email Routing + un Worker** qui alimente la table `emails`
  (configuré manuellement pour `oniq.online`).
- Pour un domaine client, il faut soit la même chose (MX → Cloudflare Email Routing, ce qui
  suppose le domaine sur Cloudflare), soit un fournisseur inbound qui pousse vers un webhook.
- Le wizard affiche les enregistrements **d'envoi** (Resend). Les enregistrements **MX de
  réception** dépendent du routage entrant retenu — à brancher selon ton choix d'infra.

> Décision à prendre de ton côté : quel mécanisme inbound pour les domaines clients
> (Cloudflare Email Routing multi-zones, Resend Inbound, ou autre). Dis-le-moi et
> j'ajoute la génération des MX + le webhook correspondant.

---

## 5. Schéma de données (rappel)

Table `emails` (alimentée par le routage entrant, lue en Realtime par OniProMail) :
`id, to_address, from_address, from_name, subject, body_text, body_html, email_date,
attachments, is_read, is_starred, folder, ai_category, client_link`

Table `email_aliases` (boîtes accessibles à l'utilisateur) :
`alias, display_name, is_shared`

---

## 6. Checklist rapide

- [ ] Clé API Resend créée
- [ ] `oniq.online` vérifié dans Resend (DKIM/SPF/DMARC)
- [ ] `RESEND_API_KEY` ajouté en secret Supabase
- [ ] `send-reply` déployée
- [ ] `domain-setup` déployée
- [ ] Test : envoyer un mail depuis OniProMail → reçu ✓
- [ ] (Scénario B) Test : ajouter un domaine client → DNS → Vérifié ✓ → envoi ✓
- [ ] (À décider) Mécanisme de réception pour les domaines clients
