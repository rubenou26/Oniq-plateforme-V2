-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — LE SCHÉMA COMPLET, DANS L'ORDRE
--
-- Le CRM d'ONIQ Software SAS. Deux maisons, deux clés techniques
-- figées dans les contraintes : bornistes = ONIQ Sur mesure,
-- tiimizy = ONIQ Logiciels. Les clés ne se renomment pas.
--
-- Tout est en « si ça n'existe pas » : le fichier est rejouable sans
-- rien écraser. Le contenu de départ d'ONIQ (catalogue, modèles,
-- fournisseurs de leads, métiers visés, tâches, règles, réglages) est
-- semé par le dernier bloc, 56-oniq-amorcage.sql. Si l'éditeur SQL de
-- Supabase s'étrangle sur la taille, exécutez à la place les fichiers
-- numérotés du dossier sql/, un par un, dans l'ordre.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 01-schema-v2.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE v2 — le CRM commercial d'ONIQ
-- Deux maisons, deux clés techniques figées : bornistes = ONIQ Sur mesure,
-- tiimizy = ONIQ Logiciels. Les clés ne se renomment pas, seuls les
-- libellés affichés changent.
-- À coller dans Supabase : SQL Editor → New query → Run.
-- Sans risque si la v1 est déjà en place : les anciennes tables ne sont
-- pas touchées, tout est préfixé ls_.
-- ═══════════════════════════════════════════════════════════════════

-- ── L'équipe ───────────────────────────────────────────────────────
create table if not exists public.ls_equipe (
  email      text primary key,
  nom        text default '',
  poste      text default '',
  role       text not null default 'commercial',   -- 'direction' | 'commercial'
  telephone  text default '',
  actif      boolean not null default true,
  cree_le    timestamptz not null default now()
);

-- ── Les comptes à démarcher ────────────────────────────────────────
create table if not exists public.ls_prospects (
  id           uuid primary key default gen_random_uuid(),
  societe      text not null,
  activite     text not null check (activite in ('tiimizy','bornistes')),
  siren        text,
  naf          text default '',
  effectif     text default '',
  ville        text default '',
  dirigeant    text default '',
  tel          text,
  email        text,
  source       text default '',
  etape        text not null default 'A contacter',
  montant      numeric default 0,
  appel_resultat text,                              -- interesse | rappeler | absent | pas_interesse | faux_numero
  rappel_le    timestamptz,
  prochaine    text default '',
  note         text default '',
  owner_email  text default '',
  perdu_motif  text default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index if not exists ls_prospects_siren_idx
  on public.ls_prospects (siren) where siren is not null;
create index if not exists ls_prospects_file_idx on public.ls_prospects (activite, etape);
create index if not exists ls_prospects_rappel_idx on public.ls_prospects (rappel_le);

-- ── Le journal des appels ──────────────────────────────────────────
create table if not exists public.ls_appels (
  id          uuid primary key default gen_random_uuid(),
  prospect_id uuid references public.ls_prospects(id) on delete set null,
  societe     text default '',
  activite    text default '',
  owner_email text default '',
  resultat    text default '',
  note        text default '',
  created_at  timestamptz not null default now()
);
create index if not exists ls_appels_jour_idx on public.ls_appels (owner_email, created_at desc);

-- ── Les prescripteurs ──────────────────────────────────────────────
create table if not exists public.ls_prescripteurs (
  id         uuid primary key default gen_random_uuid(),
  nom        text not null,
  activite   text not null check (activite in ('tiimizy','bornistes')),
  type       text default '',
  statut     text default 'A contacter',
  contact    text default '',
  tel        text default '',
  email      text default '',
  leads      integer not null default 0,
  signes     integer not null default 0,
  commission numeric default 0,
  note       text default '',
  owner_email text default '',
  -- Affiliation : le contrat et sa rémunération
  compte_email    text,                    -- le compte de connexion du partenaire
  contrat_statut  text not null default 'aucun',  -- aucun | envoye | signe | rompu
  contrat_le      date,
  contrat_texte   text default '',
  commission_type text not null default 'pourcentage', -- pourcentage | fixe_lead | fixe_signe
  commission_taux numeric not null default 10,
  commission_note text default '',
  cree_le    timestamptz not null default now()
);
create unique index if not exists ls_presc_compte_idx
  on public.ls_prescripteurs (lower(compte_email)) where compte_email is not null;

-- ── Les devis ──────────────────────────────────────────────────────
create table if not exists public.ls_devis (
  id          uuid primary key default gen_random_uuid(),
  prospect_id uuid references public.ls_prospects(id) on delete set null,
  societe     text not null,
  activite    text not null check (activite in ('tiimizy','bornistes')),
  objet       text default '',
  montant_ht  numeric not null default 0,
  acompte_pct integer not null default 30,
  statut      text not null default 'brouillon',    -- brouillon | envoye | relance | accepte | refuse
  envoye_le   date,
  decide_le   date,
  note        text default '',
  owner_email text default '',
  cree_le     timestamptz not null default now()
);

-- ── Les projets (sur mesure) et les déploiements (logiciels) ───────
-- La table garde son nom historique, ls_chantiers.
create table if not exists public.ls_chantiers (
  id         uuid primary key default gen_random_uuid(),
  devis_id   uuid references public.ls_devis(id) on delete set null,
  societe    text not null,
  activite   text not null check (activite in ('tiimizy','bornistes')),
  titre      text default '',
  statut     text not null default 'cadrage',       -- bornistes : cadrage | maquette | construction | livre
                                                   -- tiimizy   : a parametrer | reprise | formation | en service
  montant_ht numeric default 0,
  acompte_encaisse boolean not null default false,
  debut_le   date,
  fin_le     date,
  note       text default '',
  cree_le    timestamptz not null default now()
);

-- ── La to-do list ──────────────────────────────────────────────────
create table if not exists public.ls_taches (
  id        uuid primary key default gen_random_uuid(),
  titre     text not null,
  detail    text default '',
  activite  text not null default 'les_deux',       -- tiimizy | bornistes | les_deux
  nature    text not null default 'one_shot',       -- one_shot | recurrent
  charge    text default '',
  priorite  integer not null default 2,             -- 1 = chaud, 2 = normal, 3 = fond
  assignee  text default '',
  echeance  date,
  fait      boolean not null default false,
  fait_le   timestamptz,
  fait_par  text default '',
  ordre     integer not null default 100,
  cree_le   timestamptz not null default now()
);
create index if not exists ls_taches_tri_idx on public.ls_taches (fait, nature, ordre);

-- ── Les objectifs ──────────────────────────────────────────────────
create table if not exists public.ls_objectifs (
  owner_email  text not null,
  activite     text not null check (activite in ('tiimizy','bornistes')),
  appels_jour  integer not null default 30,
  rdv_semaine  integer not null default 3,
  devis_semaine integer not null default 3,
  primary key (owner_email, activite)
);

-- ── Le journal ─────────────────────────────────────────────────────
create table if not exists public.ls_activite (
  id       uuid primary key default gen_random_uuid(),
  acteur   text default '',
  action   text not null,
  cible    text default '',
  cible_id uuid,
  cree_le  timestamptz not null default now()
);
create index if not exists ls_activite_ordre_idx on public.ls_activite (cree_le desc);

-- ── Les modèles de messages ────────────────────────────────────────
create table if not exists public.ls_modeles (
  id       uuid primary key default gen_random_uuid(),
  nom      text not null,
  activite text not null default 'les_deux',
  canal    text not null default 'email',           -- email | linkedin | appel
  objet    text default '',
  corps    text default '',
  cree_le  timestamptz not null default now()
);

-- ── updated_at automatique ─────────────────────────────────────────
create or replace function public.ls_touch()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists ls_prospects_touch on public.ls_prospects;
create trigger ls_prospects_touch before update on public.ls_prospects
  for each row execute function public.ls_touch();

-- ── Les fournisseurs de leads ──────────────────────────────────────
create table if not exists public.ls_sources (
  id          uuid primary key default gen_random_uuid(),
  nom         text not null,
  activite    text not null default 'les_deux',
  genre       text not null default 'plateforme',  -- plateforme | entrant | prescripteur | sortant
  statut      text not null default 'a_brancher',  -- a_brancher | en_test | actif | coupe
  cout_lead   numeric not null default 0,
  reception   text not null default 'manuel',      -- manuel | email | webhook
  delai_min   integer not null default 5,          -- délai de rappel visé, en minutes
  url         text default '',
  identifiant text default '',
  note        text default '',
  cree_le     timestamptz not null default now()
);

-- ── Les commissions dues aux partenaires ───────────────────────────
create table if not exists public.ls_commissions (
  id            uuid primary key default gen_random_uuid(),
  partenaire_id uuid not null references public.ls_prescripteurs(id) on delete cascade,
  prospect_id   uuid references public.ls_prospects(id) on delete set null,
  devis_id      uuid references public.ls_devis(id) on delete set null,
  libelle       text not null default '',
  base_ht       numeric not null default 0,
  montant       numeric not null default 0,
  statut        text not null default 'a_valider',  -- a_valider | validee | payee | annulee
  du_le         date,
  paye_le       date,
  note          text default '',
  cree_le       timestamptz not null default now()
);
create index if not exists ls_comm_part_idx on public.ls_commissions (partenaire_id, statut);

-- ── Les notifications (équipe et partenaires) ──────────────────────
create table if not exists public.ls_notifications (
  id            uuid primary key default gen_random_uuid(),
  destinataire  text not null default '',        -- adresse e-mail
  partenaire_id uuid references public.ls_prescripteurs(id) on delete cascade,
  titre         text not null,
  corps         text default '',
  genre         text not null default 'info',    -- info | commission | contrat | lead
  lu            boolean not null default false,
  cree_le       timestamptz not null default now()
);
create index if not exists ls_notif_dest_idx on public.ls_notifications (lower(destinataire), lu);

-- ── Qui est la personne connectée ──────────────────────────────────
create or replace function public.ls_mon_role()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select role from public.ls_equipe
      where lower(email) = lower(coalesce(auth.jwt() ->> 'email','')) and actif limit 1),
    case
      when exists (select 1 from public.ls_prescripteurs
                    where lower(compte_email) = lower(coalesce(auth.jwt() ->> 'email','')))
        then 'partenaire'
      -- Amorçage : tant que l'équipe est vide, la première personne qui
      -- se connecte est la direction. Ensuite, un compte inconnu n'a
      -- aucun accès : c'est ce qui rend l'inscription libre sans danger.
      when not exists (select 1 from public.ls_equipe)
        then 'direction'
      else 'aucun'
    end);
$$;

create or replace function public.ls_mon_partenaire()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.ls_prescripteurs
   where lower(compte_email) = lower(coalesce(auth.jwt() ->> 'email','')) limit 1;
$$;

create or replace function public.ls_est_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select public.ls_mon_role() in ('direction','commercial');
$$;

-- ── Sécurité ───────────────────────────────────────────────────────
-- Deux mondes dans la même base : l'équipe voit tout, un partenaire ne
-- voit strictement que sa propre fiche, ses commissions et ses
-- notifications. C'est la base qui l'impose, pas l'écran : même en
-- fabriquant ses propres requêtes, un partenaire n'atteint rien d'autre.
do $$
declare t text;
begin
  foreach t in array array['ls_equipe','ls_prospects','ls_appels','ls_devis','ls_chantiers',
                           'ls_taches','ls_objectifs','ls_activite','ls_modeles','ls_sources']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists equipe_all on public.%I', t);
    execute format('create policy equipe_all on public.%I for all to authenticated using (public.ls_est_staff()) with check (public.ls_est_staff())', t);
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; end;
  end loop;
end $$;

alter table public.ls_prescripteurs enable row level security;
drop policy if exists equipe_all on public.ls_prescripteurs;
drop policy if exists presc_staff on public.ls_prescripteurs;
drop policy if exists presc_moi on public.ls_prescripteurs;
create policy presc_staff on public.ls_prescripteurs for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());
create policy presc_moi on public.ls_prescripteurs for select to authenticated
  using (id = public.ls_mon_partenaire());

alter table public.ls_commissions enable row level security;
drop policy if exists comm_staff on public.ls_commissions;
drop policy if exists comm_moi on public.ls_commissions;
create policy comm_staff on public.ls_commissions for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());
create policy comm_moi on public.ls_commissions for select to authenticated
  using (partenaire_id = public.ls_mon_partenaire());

alter table public.ls_notifications enable row level security;
drop policy if exists notif_staff on public.ls_notifications;
drop policy if exists notif_moi on public.ls_notifications;
drop policy if exists notif_moi_lu on public.ls_notifications;
create policy notif_staff on public.ls_notifications for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());
create policy notif_moi on public.ls_notifications for select to authenticated
  using (lower(destinataire) = lower(coalesce(auth.jwt() ->> 'email',''))
         or partenaire_id = public.ls_mon_partenaire());
create policy notif_moi_lu on public.ls_notifications for update to authenticated
  using (lower(destinataire) = lower(coalesce(auth.jwt() ->> 'email',''))
         or partenaire_id = public.ls_mon_partenaire())
  with check (lower(destinataire) = lower(coalesce(auth.jwt() ->> 'email',''))
         or partenaire_id = public.ls_mon_partenaire());

do $$
begin
  begin alter publication supabase_realtime add table public.ls_prescripteurs;
  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ls_commissions;
  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ls_notifications;
  exception when duplicate_object then null; end;
end $$;

-- ═══════════════════════════════════════════════════════════════════
-- Le contenu de départ (tâches, modèles, fournisseurs de leads) est
-- semé à la fin, par 56-oniq-amorcage.sql, une seule fois et sans
-- doublon quand on rejoue le script.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 02-schema-v2b.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — mise à jour « Affaires par secteur »
-- À exécuter après schema-v2.sql. Additif : rien n'est supprimé.
-- ═══════════════════════════════════════════════════════════════════

-- Un projet sur mesure et un déploiement de logiciel partagent la même
-- table : ce sont deux façons de livrer ce qui vient d'être vendu.
-- Seules leurs étapes diffèrent, et c'est l'activité qui les décide.
alter table public.ls_chantiers add column if not exists quantite integer not null default 0;
alter table public.ls_chantiers add column if not exists pv_signe boolean not null default false;
alter table public.ls_chantiers add column if not exists referent text default '';

-- ── Le revenu récurrent (ONIQ Logiciels) ───────────────────────────
create table if not exists public.ls_abonnements (
  id              uuid primary key default gen_random_uuid(),
  societe         text not null,
  activite        text not null default 'tiimizy',
  utilisateurs    integer not null default 0,
  montant_mois    numeric not null default 0,
  modules         text default '',
  statut          text not null default 'actif',      -- actif | suspendu | resilie
  debut_le        date,
  renouvellement_le date,
  referent        text default '',
  note            text default '',
  owner_email     text default '',
  cree_le         timestamptz not null default now()
);
create index if not exists ls_abo_renouv_idx on public.ls_abonnements (renouvellement_le);

alter table public.ls_abonnements enable row level security;
drop policy if exists equipe_all on public.ls_abonnements;
create policy equipe_all on public.ls_abonnements for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());
do $$
begin
  begin alter publication supabase_realtime add table public.ls_abonnements;
  exception when duplicate_object then null; end;
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 03-schema-v2c.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — mise à jour « Filtres de la file d'appels »
-- À exécuter après schema-v2b.sql. Additif.
-- ═══════════════════════════════════════════════════════════════════

-- Filtrer sur « 20 à 49 salariés » écrit en toutes lettres est
-- impossible : on garde le texte pour l'affichage, et on ajoute la
-- limite basse en nombre, sur laquelle une comparaison a un sens.
alter table public.ls_prospects add column if not exists effectif_num integer not null default 0;
alter table public.ls_prospects add column if not exists ca numeric not null default 0;
alter table public.ls_prospects add column if not exists code_postal text default '';

create index if not exists ls_prospects_effectif_idx on public.ls_prospects (effectif_num);
create index if not exists ls_prospects_ca_idx on public.ls_prospects (ca);
create index if not exists ls_prospects_cp_idx on public.ls_prospects (code_postal);

-- Les fiches déjà importées : on remonte la limite basse depuis le code
-- de tranche du registre, et le code postal depuis la ville.
update public.ls_prospects set effectif_num = case effectif
  when '00' then 0   when '01' then 1    when '02' then 3    when '03' then 6
  when '11' then 10  when '12' then 20   when '21' then 50   when '22' then 100
  when '31' then 200 when '32' then 250  when '41' then 500  when '42' then 1000
  when '51' then 2000 when '52' then 5000 when '53' then 10000
  else effectif_num end
where effectif_num = 0 and effectif is not null;

update public.ls_prospects
   set code_postal = substring(ville from '^[0-9]{5}')
 where (code_postal is null or code_postal = '')
   and ville ~ '^[0-9]{5}';


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 04-schema-v2d.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — mise à jour « Automatisations »
-- À exécuter après schema-v2c.sql. Additif.
--
-- Le principe : la page dans le navigateur ne peut rien envoyer toute
-- seule — elle ne tourne que si quelqu'un l'a ouverte, et une clé
-- d'envoi posée dedans serait lisible par n'importe qui. Alors le CRM
-- se contente d'écrire ce qu'il faut envoyer dans une file, et une
-- petite fonction hébergée chez Supabase passe toutes les cinq minutes
-- pour vider cette file. Les clés vivent chez Supabase, jamais dans la
-- page.
-- ═══════════════════════════════════════════════════════════════════

-- ── Les réglages de la maison ──────────────────────────────────────
-- Les valeurs propres à l'entreprise (nom d'expéditeur, SMS, adresses
-- de réponse, contrat) sont posées par 56-oniq-amorcage.sql.
create table if not exists public.ls_reglages (
  cle    text primary key,
  valeur text not null default '',
  maj_le timestamptz not null default now()
);

insert into public.ls_reglages (cle, valeur) values
  ('expediteur_email', ''),
  ('heure_debut',      '9'),
  ('heure_fin',        '18'),
  ('jours_ouvres',     'oui'),
  ('plafond_jour',     '200'),
  ('pied_email',       'Vous recevez ce message dans le cadre d''une relation professionnelle. Pour ne plus en recevoir, répondez STOP.')
on conflict (cle) do nothing;

-- ── Les règles ─────────────────────────────────────────────────────
-- Un déclencheur, un délai, un canal, un message. Rien de plus : une
-- règle qu'on ne peut pas lire à voix haute est une règle qu'on
-- n'osera pas activer.
create table if not exists public.ls_regles (
  id          uuid primary key default gen_random_uuid(),
  nom         text not null,
  actif       boolean not null default false,
  activite    text not null default 'les_deux',
  declencheur text not null,          -- voir la liste dans la fonction
  delai_min   integer not null default 0,
  canal       text not null default 'email',   -- email | sms
  objet       text default '',
  corps       text not null default '',
  eff_min     integer not null default 0,
  ca_min      numeric not null default 0,
  heures_ouvrees boolean not null default true,
  dernier_run timestamptz,
  compteur    integer not null default 0,
  cree_le     timestamptz not null default now()
);

-- ── La file d'envoi ────────────────────────────────────────────────
create table if not exists public.ls_envois (
  id            uuid primary key default gen_random_uuid(),
  cle           text unique,          -- empêche le doublon d'une même règle sur une même cible
  canal         text not null default 'email',
  destinataire  text not null,
  objet         text default '',
  corps         text not null default '',
  regle_id      uuid references public.ls_regles(id) on delete set null,
  prospect_id   uuid references public.ls_prospects(id) on delete cascade,
  partenaire_id uuid references public.ls_prescripteurs(id) on delete cascade,
  societe       text default '',
  activite      text default '',
  statut        text not null default 'en_attente', -- en_attente | envoye | echec | annule
  a_envoyer_le  timestamptz not null default now(),
  envoye_le     timestamptz,
  tentatives    integer not null default 0,
  erreur        text default '',
  owner_email   text default '',
  cree_le       timestamptz not null default now()
);
create index if not exists ls_envois_file_idx on public.ls_envois (statut, a_envoyer_le);

-- ── Les désinscrits ────────────────────────────────────────────────
-- Une liste d'opposition qui n'est pas respectée automatiquement ne
-- sert à rien : la fonction la consulte avant chaque envoi.
create table if not exists public.ls_desinscrits (
  adresse text primary key,           -- e-mail ou numéro, en minuscules
  canal   text not null default 'email',
  motif   text default '',
  cree_le timestamptz not null default now()
);

-- ── Le journal du moteur ───────────────────────────────────────────
create table if not exists public.ls_moteur (
  id        uuid primary key default gen_random_uuid(),
  fabriques integer not null default 0,
  envoyes   integer not null default 0,
  echecs    integer not null default 0,
  detail    text default '',
  cree_le   timestamptz not null default now()
);
create index if not exists ls_moteur_ordre_idx on public.ls_moteur (cree_le desc);

-- ── Sécurité ───────────────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array['ls_reglages','ls_regles','ls_envois','ls_desinscrits','ls_moteur']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists equipe_all on public.%I', t);
    execute format('create policy equipe_all on public.%I for all to authenticated using (public.ls_est_staff()) with check (public.ls_est_staff())', t);
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; end;
  end loop;
end $$;

-- ── Quelques règles prêtes à l'emploi, désactivées ─────────────────
-- Elles sont éteintes exprès : on lit, on adapte le texte, on allume.
-- Leur texte est semé par 56-oniq-amorcage.sql.


-- ═══════════════════════════════════════════════════════════════════
-- La minuterie. À exécuter APRÈS avoir déployé la fonction « moteur »
-- et remplacé les deux valeurs ci-dessous.
-- ═══════════════════════════════════════════════════════════════════
-- select vault.create_secret('https://VOTRE-PROJET.supabase.co','ls_url');
-- select vault.create_secret('COLLEZ_ICI_LA_CLE_SERVICE_ROLE','ls_cle');
--
-- select cron.schedule('ls-moteur','*/5 * * * *', $$
--   select net.http_post(
--     url := (select decrypted_secret from vault.decrypted_secrets where name='ls_url')
--            || '/functions/v1/moteur',
--     headers := jsonb_build_object(
--       'Content-Type','application/json',
--       'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='ls_cle')),
--     body := '{}'::jsonb
--   );
-- $$);
--
-- Pour arrêter la minuterie : select cron.unschedule('ls-moteur');


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 05-schema-v2e.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — mise à jour « Qualification »
-- À exécuter après schema-v2d.sql. Additif.
-- ═══════════════════════════════════════════════════════════════════

-- Une fiche de qualification par compte. Les réponses vivent en JSON —
-- le questionnaire bougera, la table ne bougera pas — et les quelques
-- champs sur lesquels on filtre ou on chiffre sont sortis en colonnes.
create table if not exists public.ls_qualif (
  prospect_id  uuid primary key references public.ls_prospects(id) on delete cascade,
  societe      text default '',
  type_site    text default '',          -- ONIQ : le secteur d'activité
  nb_bornes    integer not null default 1, -- ONIQ : le nombre d'utilisateurs
  puissance    text default '',          -- ONIQ : l'offre retenue
  reseau       text default '',          -- ONIQ : l'outil actuel
  montage      text default '',          -- ONIQ : les logiciels choisis
  tranchee     boolean not null default false,   -- colonnes historiques,
  distance_m   integer not null default 0,       -- inutilisées par ONIQ
  advenir      boolean not null default false,
  complet      integer not null default 0,   -- pourcentage de réponses
  alertes      text default '',
  recap        text default '',
  reponses     jsonb not null default '{}'::jsonb,
  par          text default '',
  maj_le       timestamptz not null default now()
);

create index if not exists ls_qualif_type_idx on public.ls_qualif (type_site);

alter table public.ls_qualif enable row level security;
drop policy if exists equipe_all on public.ls_qualif;
create policy equipe_all on public.ls_qualif for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());
do $$
begin
  begin alter publication supabase_realtime add table public.ls_qualif;
  exception when duplicate_object then null; end;
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 06-schema-v2f.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — mise à jour « Suivi des devis et pièces du dossier »
-- À exécuter après schema-v2e.sql. Additif.
-- ═══════════════════════════════════════════════════════════════════

-- Un devis n'a pas un statut, il a une histoire datée : les éléments
-- demandés, les éléments reçus, le devis parti, l'appel d'explication,
-- les relances. Un statut seul ne dit jamais depuis combien de temps
-- on attend — et c'est la seule chose qui compte.
alter table public.ls_devis add column if not exists elements_demandes_le date;
alter table public.ls_devis add column if not exists elements_recus_le   date;
alter table public.ls_devis add column if not exists appel_explication_le date;
alter table public.ls_devis add column if not exists relance1_le date;
alter table public.ls_devis add column if not exists relance2_le date;
alter table public.ls_devis add column if not exists relance3_le date;
alter table public.ls_devis add column if not exists motif_refus text default '';
alter table public.ls_devis add column if not exists prochaine   text default '';
alter table public.ls_devis add column if not exists prochaine_le date;

create index if not exists ls_devis_suivi_idx on public.ls_devis (statut, prochaine_le);

-- Les pièces du dossier, cochées une à une.
alter table public.ls_qualif add column if not exists pieces jsonb not null default '{}'::jsonb;

-- Le message de demande de pièces est semé par 56-oniq-amorcage.sql.


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 07-schema-v2g.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — mise à jour « Fournisseurs de leads »
-- À exécuter après schema-tout.sql. Additif.
-- ═══════════════════════════════════════════════════════════════════

-- Un fournisseur appartient à quelqu'un : c'est ce qui permet de servir
-- à chaque commercial ses propres leads dans sa session d'appels.
alter table public.ls_sources add column if not exists owner_email text default '';

-- Le jeton de réception : c'est NOTRE jeton, celui qu'on donne au
-- fournisseur pour qu'il s'annonce. Ce n'est pas son secret à lui —
-- une clé de fournisseur n'a rien à faire dans une table que toute
-- l'équipe peut lire.
alter table public.ls_sources add column if not exists jeton text default '';
alter table public.ls_sources add column if not exists email_reception text default '';


-- ── D'où vient chaque compte ───────────────────────────────────────
create index if not exists ls_prospects_source_idx on public.ls_prospects (source);


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 08-schema-v2h.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — mise à jour « La bonne accroche au bon moment »
-- À exécuter après schema-v2g.sql. Additif.
-- ═══════════════════════════════════════════════════════════════════

-- On n'ouvre pas de la même façon quelqu'un qui a rempli un formulaire
-- et quelqu'un qu'on dérange. Le modèle porte donc son contexte, et la
-- session d'appels sert celui qui correspond à la file en cours.
alter table public.ls_modeles add column if not exists contexte text not null default 'tous';
  -- 'lead' : la personne nous a contactés
  -- 'froid' : on l'appelle sans qu'elle ait rien demandé
  -- 'tous' : valable dans les deux cas


-- Les accroches (lead, froid, partenaire) sont semées par
-- 56-oniq-amorcage.sql.


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 09-schema-v2i.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — correctif « un lead reste un lead »
-- À exécuter après schema-v2h.sql. Additif.
-- ═══════════════════════════════════════════════════════════════════

-- La nature d'une fiche ne peut pas dépendre d'une chaîne de caractères
-- qui doit tomber juste. On la marque sur la fiche, une fois pour
-- toutes : cette personne nous a contactés, ou non.
alter table public.ls_prospects add column if not exists est_lead boolean not null default false;
create index if not exists ls_prospects_lead_idx on public.ls_prospects (est_lead, appel_resultat);

-- Rattrapage : tout ce qui vient d'un fournisseur de leads en est un.
update public.ls_prospects p set est_lead = true
 where p.est_lead = false
   and p.source in (select nom from public.ls_sources where genre <> 'sortant');

-- Les fiches saisies à la main avec « RAPPELER TOUT DE SUITE » étaient
-- des leads, elles aussi.
update public.ls_prospects set est_lead = true
 where est_lead = false and prochaine = 'RAPPELER TOUT DE SUITE';

-- Un lead sans commercial attitré revient à celui qui l'a saisi.
update public.ls_prospects set owner_email = coalesce(nullif(owner_email,''),'')
 where owner_email is null;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 10-schema-v2j.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — « d'où vient ce lead », et l'accroche en étapes
-- À exécuter après schema-v2i.sql. Additif.
-- ═══════════════════════════════════════════════════════════════════

-- Un lead n'arrive pas toujours par un formulaire : il appelle, un
-- partenaire l'envoie, on l'a croisé sur un salon. Ouvrir en disant
-- « vous avez répondu à un formulaire » à quelqu'un qui a décroché son
-- téléphone, c'est perdre les dix premières secondes.
alter table public.ls_prospects add column if not exists origine_lead text default 'formulaire';
  -- formulaire | appel | partenaire | salon | recommandation | autre

-- ── L'accroche, découpée en temps de parole ────────────────────────
-- Un paragraphe entier affiché d'un bloc ne se lit pas au téléphone.
-- Les lignes vides séparent les étapes : l'écran n'en montre qu'une,
-- et on avance au rythme de la conversation. Les accroches elles-mêmes
-- sont semées par 56-oniq-amorcage.sql.


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 11-schema-v2k.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — l'ouverture tient en une phrase
-- À exécuter après schema-appels.sql. Additif.
-- ═══════════════════════════════════════════════════════════════════

-- L'accroche posait des questions sans case pour noter la réponse, et
-- les reposait ensuite avec la case. Une seule ouverture, donc, et tout
-- le reste sous forme de questions à remplir.


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 12-schema-v2l.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2l : la session d'appels à quinze
-- Deux manques que l'audit a sortis :
--   1. rien n'empêche deux commerciaux d'appeler la même fiche
--   2. un numéro qui ne répond jamais reste dans la file indéfiniment
-- Rejouable sans risque. À exécuter après schema-appels.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 1. Réserver la fiche le temps de l'appel ──────────────────────

alter table public.ls_prospects add column if not exists en_cours_par text;
alter table public.ls_prospects add column if not exists en_cours_le  timestamptz;
create index if not exists ls_prospects_encours_idx on public.ls_prospects (en_cours_le);

-- La réservation doit être atomique : deux navigateurs qui demandent la
-- même fiche à la même seconde ne peuvent pas gagner tous les deux.
-- C'est le « where » de l'update qui tranche, pas le code de la page.
create or replace function public.ls_prendre_fiche(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_moi text := coalesce(auth.jwt() ->> 'email', '');
  v_ok  boolean;
begin
  update public.ls_prospects
     set en_cours_par = v_moi,
         en_cours_le  = now()
   where id = p_id
     and (en_cours_le is null
          or en_cours_le < now() - interval '20 minutes'
          or en_cours_par = v_moi
          or coalesce(en_cours_par,'') = '')
  returning true into v_ok;
  return coalesce(v_ok, false);
end $$;

grant execute on function public.ls_prendre_fiche(uuid) to authenticated;

-- Une réservation oubliée (onglet fermé en plein appel) ne doit pas
-- geler la fiche pour toujours : vingt minutes et elle repart.
create or replace function public.ls_liberer_fiche(p_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.ls_prospects set en_cours_par = null, en_cours_le = null
   where id = p_id and en_cours_par = coalesce(auth.jwt() ->> 'email','');
$$;

grant execute on function public.ls_liberer_fiche(uuid) to authenticated;


-- ─── 2. Compter les tentatives ─────────────────────────────────────

-- Sans compteur, un numéro qui sonne dans le vide revient tous les
-- trois jours, éternellement, et mange la file de tout le monde.
alter table public.ls_prospects add column if not exists tentatives int not null default 0;

-- Rattrapage : ce qui a déjà été noté « absent » compte pour une.
update public.ls_prospects set tentatives = 1
 where tentatives = 0 and appel_resultat = 'absent';


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 13-schema-v2m.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2m : brancher le webservice Companeo
-- Companeo ne pousse pas ses leads : c'est nous qui allons les chercher.
-- Il faut donc de quoi reconnaître un lead déjà rentré, et de quoi
-- savoir quand le dernier tirage a eu lieu.
-- Rejouable sans risque. À exécuter après schema-v2l.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 1. La référence du lead chez le fournisseur ───────────────────

-- Le webservice renvoie un lead_id. C'est la seule chose qui permette
-- d'affirmer « celui-là, on l'a déjà ». Le numéro de téléphone ne
-- suffit pas : la même société peut redemander un devis six mois plus
-- tard, et c'est alors un vrai nouveau lead.
alter table public.ls_prospects add column if not exists ref_source text;

create unique index if not exists ls_prospects_ref_source_idx
  on public.ls_prospects (source, ref_source)
  where ref_source is not null;


-- ─── 2. Le suivi des tirages ───────────────────────────────────────

alter table public.ls_sources add column if not exists dernier_tirage timestamptz;
alter table public.ls_sources add column if not exists dernier_bilan  text default '';
alter table public.ls_sources add column if not exists actif_auto     boolean not null default false;
  -- actif_auto : le moteur va chercher les leads de cette source tout seul


-- ─── 3. La fiche Companeo ──────────────────────────────────────────

-- Facultative pour ONIQ : la fiche est semée par 56-oniq-amorcage.sql,
-- sans doublon quand on rejoue le script. Le mot de passe, lui, ne
-- descend jamais ici : il vit dans les secrets de la fonction Edge. Une
-- table que toute l'équipe peut lire n'est pas un coffre-fort.


-- ─── 4. Le journal des tirages ─────────────────────────────────────

-- Pour répondre à « pourquoi ce lead n'est pas arrivé ? » sans ouvrir
-- les journaux de Supabase.
create table if not exists public.ls_tirages (
  id          uuid primary key default gen_random_uuid(),
  source      text not null default 'Companeo',
  recus       integer not null default 0,
  crees       integer not null default 0,
  doublons    integer not null default 0,
  erreur      text default '',
  fait_le     timestamptz not null default now()
);
create index if not exists ls_tirages_date_idx on public.ls_tirages (fait_le desc);

alter table public.ls_tirages enable row level security;
drop policy if exists equipe_lit on public.ls_tirages;
create policy equipe_lit on public.ls_tirages for select to authenticated using (true);


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 14-schema-v2n.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2n : recruter des partenaires au téléphone
--
-- Un partenaire ne se qualifie pas comme un client : on ne lui vend
-- rien, on lui propose de gagner de l'argent sur ce qu'il refuse
-- aujourd'hui. D'où une accroche à lui, des questions à lui, et une
-- fiche qui se remplit toute seule dans l'écran Affiliation.
--
-- Rejouable sans risque. À exécuter après schema-v2m.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 1. Ce qu'on a appris pendant l'appel ──────────────────────────

alter table public.ls_prescripteurs add column if not exists qualif jsonb not null default '{}'::jsonb;
alter table public.ls_prescripteurs add column if not exists appel_resultat text;
alter table public.ls_prescripteurs add column if not exists rappel_le      timestamptz;
alter table public.ls_prescripteurs add column if not exists dernier_appel  timestamptz;
alter table public.ls_prescripteurs add column if not exists volume_estime  integer not null default 0;

create index if not exists ls_presc_file_idx on public.ls_prescripteurs (statut, appel_resultat);
create index if not exists ls_presc_rappel_idx on public.ls_prescripteurs (rappel_le);


-- ─── 2. Les accroches et le mail d'après l'appel ──────────────────

-- Le ressort n'est pas « travaillez avec nous » mais « vos clients
-- vous parlent de leurs outils, et ça peut vous rapporter ». L'accroche
-- de recrutement et le mail envoyé après un oui sont semés par
-- 56-oniq-amorcage.sql.


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 15-schema-v2o.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2o : l'espace partenaire, de l'invitation au contrat
--
-- Le parcours : le commercial invite → le partenaire reçoit un lien →
-- il choisit son mot de passe → il signe le contrat d'affiliation →
-- il installe l'application sur son téléphone → il voit ses leads et
-- ses commissions.
--
-- Tout ce qui compte est fait par la base, pas par la page : un
-- partenaire qui fabrique ses propres requêtes n'atteint que sa
-- propre fiche.
--
-- Rejouable sans risque. À exécuter après schema-v2n.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 1. L'invitation et la signature ───────────────────────────────

alter table public.ls_prescripteurs add column if not exists invite_jeton   text;
alter table public.ls_prescripteurs add column if not exists invite_le      timestamptz;
alter table public.ls_prescripteurs add column if not exists invite_expire  timestamptz;
alter table public.ls_prescripteurs add column if not exists signature_nom  text;
alter table public.ls_prescripteurs add column if not exists signature_le   timestamptz;
alter table public.ls_prescripteurs add column if not exists cgv_version    text default '';

create unique index if not exists ls_presc_jeton_idx
  on public.ls_prescripteurs (invite_jeton) where invite_jeton is not null;


-- ─── 2. Les leads que le partenaire a apportés ─────────────────────

alter table public.ls_prospects add column if not exists partenaire_id uuid
  references public.ls_prescripteurs(id) on delete set null;
create index if not exists ls_prospects_part_idx on public.ls_prospects (partenaire_id);


-- ─── 3. Lire une invitation sans être connecté ─────────────────────

-- La page d'accueil du partenaire doit afficher son nom et sa
-- commission avant qu'il ait un compte. Elle ne peut donc pas passer
-- par les politiques normales : cette fonction est la seule porte, et
-- elle ne rend que ce qu'il faut pour l'accueillir. Ni téléphone, ni
-- notes internes, ni les autres partenaires.
create or replace function public.ls_invitation(p_jeton text)
returns table (
  nom text, email text, activite text,
  commission_type text, commission_taux numeric, commission_note text,
  contrat_texte text, contrat_statut text, deja_lie boolean,
  contrat_modele text, contrat_version text
)
language sql
security definer
set search_path = public
as $$
  select p.nom, p.email, p.activite,
         p.commission_type, p.commission_taux, p.commission_note,
         p.contrat_texte, p.contrat_statut,
         (coalesce(p.compte_email,'') <> '') as deja_lie,
         (select valeur from public.ls_reglages where cle = 'contrat_modele'),
         (select valeur from public.ls_reglages where cle = 'contrat_version')
    from public.ls_prescripteurs p
   where p.invite_jeton = p_jeton
     and p_jeton is not null and length(p_jeton) >= 20
     and (p.invite_expire is null or p.invite_expire > now())
   limit 1;
$$;

grant execute on function public.ls_invitation(text) to anon, authenticated;


-- ─── 4. Rattacher le compte fraîchement créé ───────────────────────

-- Appelée une fois, juste après l'inscription. Elle consomme le jeton :
-- un lien d'invitation ne sert qu'une fois.
create or replace function public.ls_lier_compte(p_jeton text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_moi text := coalesce(auth.jwt() ->> 'email', '');
  v_ok  boolean;
begin
  if v_moi = '' then return false; end if;

  update public.ls_prescripteurs
     set compte_email  = v_moi,
         invite_jeton  = null,
         invite_expire = null
   where invite_jeton = p_jeton
     and p_jeton is not null and length(p_jeton) >= 20
     and (invite_expire is null or invite_expire > now())
     and (compte_email is null or compte_email = '' or compte_email = v_moi)
  returning true into v_ok;

  return coalesce(v_ok, false);
end $$;

grant execute on function public.ls_lier_compte(text) to authenticated;


-- ─── 5. Signer le contrat ──────────────────────────────────────────

-- La signature est un acte : elle porte un nom, une date, et le texte
-- exact qui était à l'écran. Sans la version du texte, une signature
-- ne prouve rien — on ne saurait pas ce qui a été signé.
create or replace function public.ls_signer_contrat(p_nom text, p_version text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := public.ls_mon_partenaire();
  v_ok boolean;
begin
  if v_id is null or coalesce(btrim(p_nom),'') = '' then return false; end if;

  update public.ls_prescripteurs
     set contrat_statut = 'signe',
         contrat_le     = current_date,
         signature_nom  = btrim(p_nom),
         signature_le   = now(),
         cgv_version    = coalesce(p_version,''),
         statut         = case when statut in ('A contacter','En discussion') then 'Signé' else statut end
   where id = v_id
  returning true into v_ok;

  insert into public.ls_notifications (partenaire_id, titre, corps)
  values (v_id, 'Contrat signé',
          'Votre contrat d''affiliation est signé. Vous pouvez maintenant nous adresser vos premiers contacts.');

  return coalesce(v_ok, false);
end $$;

grant execute on function public.ls_signer_contrat(text, text) to authenticated;


-- ─── 6. Le partenaire voit les affaires qu'il a apportées ──────────

drop policy if exists partenaire_voit_ses_leads on public.ls_prospects;
create policy partenaire_voit_ses_leads on public.ls_prospects
  for select to authenticated
  using (
    public.ls_mon_role() <> 'partenaire'
    or partenaire_id = public.ls_mon_partenaire()
  );


-- ─── 7. Le texte du contrat, modifiable sans toucher au code ───────
-- Il vit dans ls_reglages (contrat_modele, contrat_version) et il est
-- posé par 56-oniq-amorcage.sql.


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 16-schema-v2p.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2p : les envois déclenchés à la main partent seuls
--
-- Jusqu'ici, deux mondes : les règles qui envoient toutes seules, et
-- les messages qu'un commercial devait copier-coller dans sa
-- messagerie. Le deuxième monde disparaît : tout passe par la même
-- file, tout part par le même moteur.
--
-- La seule différence : un message qu'une personne attend — une
-- invitation, une demande de pièces — ne doit pas dormir jusqu'à
-- 9 h du matin. Il est marqué prioritaire et ignore les heures
-- d'envoi, qui ne sont là que pour la prospection.
--
-- Rejouable sans risque. À exécuter après schema-v2o.sql.
-- ═══════════════════════════════════════════════════════════════════

alter table public.ls_envois add column if not exists prioritaire boolean not null default false;
alter table public.ls_envois add column if not exists declenche_par text default '';

create index if not exists ls_envois_prio_idx
  on public.ls_envois (statut, prioritaire desc, a_envoyer_le);

-- Le plafond quotidien protège de l'emballement d'une règle. Un
-- message qu'un commercial vient de déclencher n'a rien à voir avec
-- ça : il en est exclu, sinon la deux-cent-unième invitation de la
-- journée disparaîtrait sans que personne ne le sache.
comment on column public.ls_envois.prioritaire is
  'Déclenché par une personne, attendu par le destinataire : ignore les heures d''envoi et le plafond.';


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 17-schema-v2q.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2q : où atterrissent les réponses
--
-- Un sous-domaine d'envoi n'a pas de boîte aux lettres, et il n'en a
-- pas besoin. Mais un message qui se termine par « répondez STOP »
-- doit bien arriver quelque part quand quelqu'un répond — sinon la
-- réponse rebondit dans le vide, et l'opposition n'est jamais
-- enregistrée. On sépare donc l'adresse qui signe de l'adresse qui
-- reçoit.
--
-- Rejouable sans risque. À exécuter après schema-v2p.sql.
-- ═══════════════════════════════════════════════════════════════════

insert into public.ls_reglages (cle, valeur) values
  ('repondre_a', '')
on conflict (cle) do nothing;

comment on table public.ls_reglages is
  'Réglages de la maison. expediteur_email signe les messages et doit appartenir au domaine '
  'vérifié chez le fournisseur. repondre_a est la boîte réelle où arrivent les réponses : '
  'sans elle, un « répondez STOP » ne mène nulle part.';


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 18-schema-v2r.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2r : un expéditeur par maison
--
-- Les règles savent déjà à quelle activité elles s'appliquent, mais
-- l'expéditeur était unique pour les deux. Un prospect des logiciels
-- recevait donc un message signé au nom de l'autre maison : la
-- meilleure façon de se faire signaler comme indésirable.
--
-- Les clés génériques restent la valeur par défaut. Une clé vide pour
-- une maison veut dire « prends celle du dessus ».
--
-- Rejouable sans risque. À exécuter après schema-v2q.sql.
-- ═══════════════════════════════════════════════════════════════════

insert into public.ls_reglages (cle, valeur) values
  ('expediteur_nom_bornistes',   ''),
  ('expediteur_email_bornistes', ''),
  ('repondre_a_bornistes',       ''),
  ('sms_expediteur_bornistes',   ''),
  ('expediteur_nom_tiimizy',     ''),
  ('expediteur_email_tiimizy',   ''),
  ('repondre_a_tiimizy',         ''),
  ('sms_expediteur_tiimizy',     '')
on conflict (cle) do nothing;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 19-schema-v2s.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2s : les modèles d'e-mail du quotidien
--
-- Six messages que le commercial envoie vraiment, écrits pour partir
-- en un clic depuis la session d'appels. Ils sont volontairement
-- courts : un e-mail commercial qui dépasse l'écran du téléphone
-- n'est pas lu.
--
-- Ils sont semés par 56-oniq-amorcage.sql.
--
-- Rejouable sans risque. À exécuter après schema-v2r.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 20-schema-v2t.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2t : chaque commercial écrit en son nom
--
-- Un message qui arrive de « contact@ » n'a pas d'auteur. Le client
-- répond dans le vide, et le commercial qui l'a eu au téléphone ne
-- voit jamais la réponse.
--
-- Chaque envoi porte donc désormais son propre expéditeur, déduit du
-- compte de la personne qui l'a déclenché — ou, pour un envoi
-- automatique, du commercial à qui la fiche appartient.
--
-- Rejouable sans risque. À exécuter après schema-v2s.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 1. L'expéditeur voyage avec le message ────────────────────────

alter table public.ls_envois add column if not exists expediteur_nom   text default '';
alter table public.ls_envois add column if not exists expediteur_email text default '';
alter table public.ls_envois add column if not exists repondre_a       text default '';

comment on column public.ls_envois.expediteur_email is
  'Adresse personnelle du commercial, sur le sous-domaine authentifié. '
  'Vide : on retombe sur l''adresse de la maison.';


-- ─── 2. De quoi forcer une adresse au cas par cas ──────────────────

-- Par défaut on déduit : prenom@oniq.online devient
-- prenom@mail.oniq.online, et les réponses reviennent sur la
-- boîte d'origine. Ces deux colonnes ne servent qu'aux exceptions —
-- quelqu'un dont l'identifiant de connexion n'est pas sa vraie
-- adresse, par exemple.
alter table public.ls_equipe add column if not exists envoi_nom   text default '';
alter table public.ls_equipe add column if not exists envoi_email text default '';
alter table public.ls_equipe add column if not exists repondre_a  text default '';


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 21-schema-v2u.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2u : des mails habillés, signés, avec leurs pièces
--
-- Trois manques :
--   1. les mails partaient en texte brut, sans identité visuelle
--   2. la signature du commercial n'existait nulle part
--   3. il fallait joindre la plaquette et les catalogues à la main
--
-- Rejouable sans risque. À exécuter après schema-v2t.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 1. La signature du commercial ─────────────────────────────────

-- Un mail signé d'un simple prénom, sans numéro, oblige le client à chercher.
alter table public.ls_equipe add column if not exists tel      text default '';
alter table public.ls_equipe add column if not exists fonction text default '';


-- ─── 2. La bibliothèque de documents ───────────────────────────────

-- Plaquette, catalogues, présentations. Ils vivent dans le stockage
-- Supabase et sont joints par leur adresse : rien ne transite en
-- base 64 dans la file d'envoi, qui doit rester légère.
create table if not exists public.ls_documents (
  id        uuid primary key default gen_random_uuid(),
  nom       text not null,
  fichier   text not null,                    -- l'adresse publique du fichier
  categorie text not null default 'general',  -- general | catalogue | devis | presentation
  activite  text not null default 'les_deux',
  taille    integer not null default 0,       -- en octets, pour prévenir avant l'envoi
  ordre     integer not null default 100,
  cree_le   timestamptz not null default now()
);
create index if not exists ls_documents_cat_idx on public.ls_documents (categorie, ordre);

alter table public.ls_documents enable row level security;
drop policy if exists equipe_all on public.ls_documents;
create policy equipe_all on public.ls_documents for all to authenticated
  using (public.ls_mon_role() <> 'partenaire')
  with check (public.ls_mon_role() <> 'partenaire');


-- ─── 3. Ce qu'un modèle emporte avec lui ───────────────────────────

-- Les pièces jointes par défaut du modèle. Le commercial peut en
-- retirer au moment d'envoyer : c'est un point de départ, pas une
-- obligation.
alter table public.ls_modeles add column if not exists pieces jsonb not null default '[]'::jsonb;

-- Le corps habillé, calculé au moment de l'envoi. On le garde tel
-- quel dans la file : ce qui est parti doit rester consultable.
alter table public.ls_envois  add column if not exists corps_html text default '';
alter table public.ls_envois  add column if not exists pieces jsonb not null default '[]'::jsonb;


-- ─── 4. Le rangement des fichiers ──────────────────────────────────

-- Un seau public : ces documents sont faits pour être lus par des
-- clients qui n'ont pas de compte chez nous.
insert into storage.buckets (id, name, public)
values ('documents', 'documents', true)
on conflict (id) do nothing;

drop policy if exists documents_lecture on storage.objects;
create policy documents_lecture on storage.objects for select
  using (bucket_id = 'documents');

drop policy if exists documents_depot on storage.objects;
create policy documents_depot on storage.objects for insert to authenticated
  with check (bucket_id = 'documents');

drop policy if exists documents_maj on storage.objects;
create policy documents_maj on storage.objects for update to authenticated
  using (bucket_id = 'documents');

drop policy if exists documents_suppr on storage.objects;
create policy documents_suppr on storage.objects for delete to authenticated
  using (bucket_id = 'documents');


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 22-schema-v2v.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2v : quelles pièces avec quel message
--
-- À exécuter APRÈS avoir déposé les documents dans le CRM
-- (Modèles → Déposer un document). Les pièces sont désignées par
-- leur nom de fichier : si vous les renommez, reprenez ce fichier.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

-- Aucune pièce n'est posée d'office sur les modèles d'ONIQ : ils sont
-- semés avec pieces = '[]' par 56-oniq-amorcage.sql. Une fois la
-- plaquette déposée, on la rattache au modèle depuis l'écran Modèles.


-- Ce qui reste, pour vérifier d'un coup d'œil.
select nom, jsonb_array_length(pieces) as pieces_jointes, canal
  from public.ls_modeles
 where canal = 'email'
 order by nom;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 23-schema-v2w.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2w : qui signe, et où le client répond
--
-- L'identifiant d'une personne, c'est la partie avant le @ de son
-- adresse professionnelle — plus celle de son compte de connexion.
-- Se connecter avec un Gmail devient sans conséquence : le client ne
-- le voit jamais.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

-- ─── L'adresse professionnelle de chacun ───────────────────────────

-- Chacun la renseigne sur sa fiche (écran Équipe) : quelqu'un qui se
-- connecte avec un Gmail écrit quand même depuis son adresse pro.


-- Les deux jeux de colonnes tenus d'accord (poste/telephone d'avant,
-- fonction/tel depuis v2u) : la signature lit les seconds.
update public.ls_equipe set fonction = poste     where coalesce(fonction,'') = '' and coalesce(poste,'')     <> '';
update public.ls_equipe set poste    = fonction  where coalesce(poste,'')    = '' and coalesce(fonction,'')  <> '';
update public.ls_equipe set tel      = telephone where coalesce(tel,'')      = '' and coalesce(telephone,'') <> '';
update public.ls_equipe set telephone = tel      where coalesce(telephone,'')= '' and coalesce(tel,'')       <> '';

-- Aucun passe-droit ne doit traîner : une adresse figée là écraserait
-- la maison du destinataire et ferait écrire un commercial des
-- logiciels depuis l'adresse du sur-mesure.
update public.ls_equipe set envoi_email = '' where coalesce(envoi_email,'') <> '';
update public.ls_equipe set envoi_nom   = '' where coalesce(envoi_nom,'')   <> '';


-- ─── Le domaine de réponse, maison par maison ──────────────────────

-- C'est ce domaine qui, combiné à l'identifiant, donne l'adresse de
-- réponse : « prenom » + « oniq.online » → prenom@oniq.online. Les
-- valeurs (repondre_a_bornistes, repondre_a_tiimizy) sont posées par
-- 56-oniq-amorcage.sql.


-- ─── Ce que ça donne ───────────────────────────────────────────────
select e.email            as se_connecte_avec,
       e.nom, e.fonction, e.tel,
       e.repondre_a       as adresse_pro,
       split_part(coalesce(nullif(e.repondre_a,''), e.email),'@',1)
         || '@' || split_part(
              (select valeur from public.ls_reglages where cle='expediteur_email_bornistes'),'@',2)
                          as ecrit_aux_clients_bornistes,
       split_part(coalesce(nullif(e.repondre_a,''), e.email),'@',1)
         || '@' || split_part(
              (select valeur from public.ls_reglages where cle='expediteur_email_tiimizy'),'@',2)
                          as ecrit_aux_clients_tiimizy
  from public.ls_equipe e
 order by e.email;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 24-schema-v2x.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2x : les pièces jointes, sur les vrais noms
--
-- Une pièce désignée par un nom qui n'existe pas ne lève aucune
-- erreur : elle manque, simplement, et personne ne le voit. Le
-- réalignement propre aux anciens modèles est retiré ; il reste le
-- contrôle, rejouable après tout dépôt.
-- ═══════════════════════════════════════════════════════════════════

-- ─── Contrôle : chaque pièce citée existe-t-elle vraiment ? ────────
select m.nom as modele,
       piece.valeur as piece_citee,
       case when exists (select 1 from public.ls_documents d
                          where d.nom = piece.valeur)
            then 'présente' else '⚠ INTROUVABLE' end as etat
  from public.ls_modeles m
  cross join lateral jsonb_array_elements_text(coalesce(m.pieces,'[]'::jsonb)) as piece(valeur)
 where m.canal = 'email'
 order by m.nom, piece.valeur;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 25-schema-v2y.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2y : le catalogue, et le devis chiffré tout seul
--
-- Les prix vivent en base, pas dans le code : le jour où le
-- fournisseur augmente, on change une ligne ici et tous les devis
-- suivent, sans redéploiement.
--
-- La colonne `role` est ce que le chiffrage cherche. La référence,
-- elle, ne sert qu'à retrouver l'article dans l'outil de facturation.
-- On peut donc changer d'offre en réaffectant les rôles. Les articles
-- d'ONIQ (sur mesure et logiciels) sont semés par 56-oniq-amorcage.sql.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.ls_catalogue (
  id          uuid primary key default gen_random_uuid(),
  reference   text not null unique,
  designation text not null default '',
  role        text not null default '',
  unite       text not null default 'u',      -- u | m | forfait | mois
  pv_ht       numeric not null default 0,
  tva         numeric not null default 20,
  a_confirmer boolean not null default false, -- prix provisoire, à confirmer avant d'engager un devis
  actif       boolean not null default true,
  maj_le      timestamptz not null default now()
);

alter table public.ls_catalogue enable row level security;
drop policy if exists ls_catalogue_lecture on public.ls_catalogue;
create policy ls_catalogue_lecture on public.ls_catalogue
  for select to authenticated using (true);
drop policy if exists ls_catalogue_ecriture on public.ls_catalogue;
create policy ls_catalogue_ecriture on public.ls_catalogue
  for all to authenticated using (true) with check (true);

-- Le devis garde ses lignes et la qualification qui l'a produit :
-- six mois plus tard, on doit pouvoir dire pourquoi ce prix-là.
alter table public.ls_devis add column if not exists lignes   jsonb default '[]'::jsonb;
alter table public.ls_devis add column if not exists chiffrage jsonb default '{}'::jsonb;


-- ─── Ce qui est prêt, et ce qui bloque ─────────────────────────────
select role, reference, unite, pv_ht,
       case when pv_ht = 0 then '⚠ prix manquant'
            when a_confirmer then 'forfait à confirmer'
            else 'ok' end as etat
  from public.ls_catalogue
 where actif
 order by (pv_ht = 0) desc, a_confirmer desc, role;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 26-schema-v2z.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v2z : l'adresse du site client
--
-- Les fournisseurs de leads la transmettent. La ressaisir pendant
-- l'appel fait perdre trente secondes et introduit des fautes.
--
-- Elle est distincte de la ville : c'est l'adresse du site où l'on
-- intervient, pas forcément celle du siège.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

alter table public.ls_prospects add column if not exists adresse text default '';

-- Les leads déjà en base n'ont que la ville : on s'en sert comme point
-- de départ, le commercial complétera. Mieux vaut une adresse
-- incomplète qu'un champ vide qu'il faudra remplir de mémoire.
update public.ls_prospects
   set adresse = ville
 where coalesce(adresse,'') = ''
   and coalesce(ville,'')  <> '';

-- Certains fournisseurs transmettent l'adresse dans leurs réponses : on la remonte dans
-- la fiche quand elle y est, sans écraser une saisie manuelle.
update public.ls_prospects p
   set adresse = q.reponses->>'adresse'
  from public.ls_qualif q
 where q.prospect_id = p.id
   and coalesce(q.reponses->>'adresse','') <> ''
   and (coalesce(p.adresse,'') = '' or p.adresse = p.ville);

select count(*) filter (where coalesce(adresse,'') <> '') as avec_adresse,
       count(*) filter (where coalesce(adresse,'') =  '') as sans_adresse,
       count(*) as total
  from public.ls_prospects;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 27-schema-v3a.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3a : retiré pour ONIQ
--
-- Ce bloc ajustait le catalogue de l'ancien métier. Il ne contient plus
-- rien : le catalogue d'ONIQ est semé par 56-oniq-amorcage.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 28-schema-v3b.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3b : l'acompte à la commande
--
-- Les articles de l'ancien métier qui étaient ici sont retirés : le
-- catalogue d'ONIQ est semé par 56-oniq-amorcage.sql.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════


-- ─── L'acompte ─────────────────────────────────────────────────────
-- 50 % à la commande, 50 % à la livraison : c'est la valeur par défaut
-- d'un devis neuf. Elle se change devis par devis.
alter table public.ls_devis alter column acompte_pct set default 50;
update public.ls_devis set acompte_pct = 50 where acompte_pct = 30 and statut = 'brouillon';


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 29-schema-v3c.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3c : retiré pour ONIQ
--
-- Ce bloc posait les règles de chiffrage de l'ancien métier. Il ne
-- contient plus rien : le catalogue d'ONIQ est semé par
-- 56-oniq-amorcage.sql, et les règles de chiffrage vivent dans la page.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 30-schema-v3d.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3d : retiré pour ONIQ
--
-- Ce bloc tarifait des prestations de l'ancien métier. Il ne contient
-- plus rien : le catalogue d'ONIQ est semé par 56-oniq-amorcage.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 31-schema-v3e.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3e : les notifications push de l'espace partenaire
--
-- Gratuit et sans intermédiaire : le navigateur du partenaire s'abonne
-- auprès de son propre fabricant (Google, Apple, Mozilla), nous garde
-- une adresse d'envoi, et le moteur y dépose les messages. Aucun
-- service tiers, aucun abonnement, aucune limite.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.ls_push (
  id          uuid primary key default gen_random_uuid(),
  partenaire_id uuid references public.ls_prescripteurs(id) on delete cascade,
  email       text default '',
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  appareil    text default '',
  actif       boolean not null default true,
  cree_le     timestamptz not null default now(),
  vu_le       timestamptz
);
create index if not exists ls_push_part_idx on public.ls_push (partenaire_id) where actif;

alter table public.ls_push enable row level security;

-- Un partenaire n'inscrit et ne retire que ses propres appareils.
drop policy if exists ls_push_sien on public.ls_push;
create policy ls_push_sien on public.ls_push
  for all to authenticated
  using  (email = auth.jwt() ->> 'email')
  with check (email = auth.jwt() ->> 'email');

-- L'équipe voit les abonnements pour diagnostiquer, sans les modifier.
drop policy if exists ls_push_equipe on public.ls_push;
create policy ls_push_equipe on public.ls_push
  for select to authenticated
  using (exists (select 1 from public.ls_equipe e
                  where e.email = auth.jwt() ->> 'email' and e.actif));


-- La file d'envoi accepte un troisième canal.
alter table public.ls_envois drop constraint if exists ls_envois_canal_check;
alter table public.ls_envois add constraint ls_envois_canal_check
  check (canal in ('email','sms','push'));


-- La clé publique VAPID : elle est publique par construction, c'est
-- elle que le navigateur du partenaire présente à son fabricant. La
-- clé privée, elle, ne quitte jamais les secrets de la fonction Edge.
-- Chaque projet génère sa propre paire (npx web-push generate-vapid-keys) :
-- la ligne vapid_public est créée vide par 56-oniq-amorcage.sql, à
-- remplir avec la même valeur que le secret VAPID_PUBLIC.


select 'ls_push créée' as etape,
       (select count(*) from public.ls_push) as abonnements;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 32-schema-v3f.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3f : retrouver le devis, et des mails plus courts
--
-- Deux choses sans rapport, réunies parce qu'elles se posent ensemble.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

-- ─── 1. L'adresse du PDF envoyé ────────────────────────────────────
-- Le PDF est le document ; la fiche n'en est que la trace. Sans son
-- adresse, personne ne peut relire ce que le client a réellement reçu
-- — et c'est la première chose qu'on cherche quand il rappelle.
alter table public.ls_devis add column if not exists pdf_url text default '';


-- ─── 2. Les modèles d'e-mail, courts ──────────────────────────────
--
-- Un mail commercial se lit sur un téléphone, entre deux rendez-vous.
-- Deux phrases qui demandent une chose précise sont lues ; trois
-- paragraphes qui expliquent le métier ne le sont pas. Les modèles
-- d'ONIQ sont écrits sur ce principe et semés par 56-oniq-amorcage.sql.
--
-- La signature, les coordonnées et les preuves sont ajoutées
-- automatiquement à l'envoi : inutile de les répéter dans le texte.


select nom, length(corps) as caracteres, objet
  from public.ls_modeles
 where canal = 'email'
 order by length(corps) desc;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 33-schema-v3g.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3g : la règle qui déclenche les notifications
--
-- Le tuyau du push était posé — table, clés, moteur — mais rien n'y
-- entrait : aucune règle ne produisait de message sur ce canal. Voici
-- la pièce manquante.
--
-- Elle reste ÉTEINTE. On l'allume après avoir vu une notification
-- arriver sur un téléphone de test.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

-- Le canal push rejoint les canaux autorisés d'une règle.
alter table public.ls_regles drop constraint if exists ls_regles_canal_check;
alter table public.ls_regles add constraint ls_regles_canal_check
  check (canal in ('email','sms','push'));

-- Une notification n'est pas un e-mail : elle tient sur deux lignes,
-- elle annonce le montant, et elle s'arrête là. Le détail est dans
-- l'espace partenaire, à un doigt de distance. La règle est semée,
-- éteinte, par 56-oniq-amorcage.sql.


-- L'ancienne règle par e-mail reste disponible : certains partenaires
-- n'installeront jamais l'application, et un e-mail les atteint quand
-- même. Les deux peuvent tourner ensemble sans faire doublon gênant —
-- une notification se lit dans la seconde, l'e-mail sert de trace.


-- ─── Ce qui est en place ───────────────────────────────────────────
select nom, canal, declencheur,
       case when actif then 'ALLUMÉE' else 'éteinte' end as etat
  from public.ls_regles
 order by canal, nom;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 34-schema-v3h.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3h
--
-- Deux corrections pour l'espace partenaire :
--
--   1. La clé publique de notification était rangée dans ls_reglages,
--      table réservée à l'équipe. Un partenaire qui cliquait
--      « Activer » lisait donc zéro ligne — sans erreur, RLS filtre en
--      silence — et l'écran annonçait « clé non configurée côté
--      serveur ». On ne desserre pas ls_reglages pour autant : une
--      petite fonction rend cette seule clé, qui est publique par
--      construction.
--
--   2. Un partenaire qui ouvre son invitation sur un ordinateur ne
--      recevra jamais de notification : elles vivent sur le téléphone.
--      Il peut désormais se renvoyer son lien par e-mail en un clic.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

-- ─── 1. La clé publique de notification ────────────────────────────

create or replace function public.ls_cle_push()
returns text
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((select valeur from public.ls_reglages where cle = 'vapid_public'), '');
$$;

grant execute on function public.ls_cle_push() to anon, authenticated;


-- ─── 2. L'adresse publique du site ─────────────────────────────────
-- Elle sert à fabriquer le lien mobile côté serveur, plutôt que de
-- faire confiance à ce que le navigateur nous enverrait. La ligne
-- site_url est créée vide par 56-oniq-amorcage.sql : à remplir avec
-- l'adresse Netlify une fois le site déployé.


-- ─── 3. « Envoyez-moi le lien sur mon téléphone » ───────────────────
-- Le partenaire est connecté ; on n'accepte donc aucune adresse de sa
-- part : le message part vers l'adresse inscrite sur sa fiche. Un
-- envoi par heure et par partenaire, la clé unique s'en charge.

create or replace function public.ls_lien_mobile()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_moi  text := coalesce(auth.jwt() ->> 'email', '');
  p      public.ls_prescripteurs%rowtype;
  v_site text;
  v_lien text;
  v_jeton text;
begin
  if v_moi = '' then return 'non-connecte'; end if;

  select * into p from public.ls_prescripteurs
   where compte_email = v_moi limit 1;
  if not found or coalesce(p.email,'') = '' then return 'sans-fiche'; end if;

  select valeur into v_site from public.ls_reglages where cle = 'site_url';
  v_site := coalesce(v_site, '');
  if v_site = '' then return 'sans-adresse'; end if;

  -- Le compte existe déjà : un lien d'invitation serait inutile, on
  -- envoie l'adresse de connexion.
  v_jeton := coalesce(p.invite_jeton, '');
  v_lien  := case when length(v_jeton) >= 20
                  then v_site || '#bienvenue=' || v_jeton
                  else v_site end;

  insert into public.ls_envois
    (cle, canal, destinataire, objet, corps, partenaire_id, societe, activite, statut)
  values (
    'mobile:' || p.id::text || ':' || to_char(now(), 'YYYYMMDDHH24'),
    'email', p.email,
    'Votre espace partenaire sur votre téléphone',
    'Bonjour ' || coalesce(p.contact, p.nom, '') || ',' || chr(10) || chr(10) ||
    'Voici le lien à ouvrir depuis votre téléphone pour installer votre espace partenaire :' ||
    chr(10) || chr(10) || v_lien || chr(10) || chr(10) ||
    'Une fois installé, vous êtes prévenu par notification dès qu''une de vos commissions est validée — sans avoir à ouvrir vos mails.' ||
    chr(10) || chr(10) || 'À très vite,' || chr(10) || 'ONIQ',
    p.id, p.nom, p.activite, 'en_attente')
  on conflict (cle) do nothing;

  return p.email;
end $$;

grant execute on function public.ls_lien_mobile() to authenticated;


select 'v3h posée' as etape,
       public.ls_cle_push() <> '' as cle_push_lisible,
       (select valeur from public.ls_reglages where cle = 'site_url') as adresse_du_site;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 35-schema-v3i.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3i : l'invitation vit tant qu'il n'y a pas de compte
--
-- Une invitation à usage unique et datée à trente jours était une
-- fausse bonne idée. Un partenaire ouvre le lien, regarde, referme,
-- y revient trois jours plus tard depuis son téléphone : il tombait
-- sur « lien expiré » et rappelait son commercial. La sécurité réelle
-- n'est pas dans la date, elle est dans le jeton lui-même — 48
-- caractères tirés au hasard — et dans le fait qu'il meurt à la
-- seconde où le compte est créé.
--
-- Nouvelle règle, unique et lisible : le lien fonctionne tant que le
-- partenaire n'a pas créé son compte. Ensuite il ne sert plus à rien,
-- puisqu'il se connecte.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

-- ─── 1. Les invitations en cours n'expirent plus ───────────────────

update public.ls_prescripteurs
   set invite_expire = null
 where coalesce(compte_email, '') = ''
   and invite_jeton is not null;


-- ─── 2. La porte d'entrée ne regarde plus la date ──────────────────

create or replace function public.ls_invitation(p_jeton text)
returns table (
  nom text, email text, activite text,
  commission_type text, commission_taux numeric, commission_note text,
  contrat_texte text, contrat_statut text, deja_lie boolean,
  contrat_modele text, contrat_version text
)
language sql
security definer
set search_path = public
as $$
  select p.nom, p.email, p.activite,
         p.commission_type, p.commission_taux, p.commission_note,
         p.contrat_texte, p.contrat_statut,
         (coalesce(p.compte_email,'') <> '') as deja_lie,
         (select valeur from public.ls_reglages where cle = 'contrat_modele'),
         (select valeur from public.ls_reglages where cle = 'contrat_version')
    from public.ls_prescripteurs p
   where p.invite_jeton = p_jeton
     and p_jeton is not null and length(p_jeton) >= 20
     -- Plus de date : seul compte l'existence d'un compte. Une
     -- invitation dont le compte est déjà créé reste lisible le temps
     -- que la personne finisse de signer, et rien de plus.
   limit 1;
$$;

grant execute on function public.ls_invitation(text) to anon, authenticated;


-- ─── 3. Le rattachement ne regarde plus la date non plus ───────────
-- Il continue en revanche de consommer le jeton : c'est là, et
-- seulement là, que le lien cesse de valoir quelque chose.

create or replace function public.ls_lier_compte(p_jeton text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_moi text := coalesce(auth.jwt() ->> 'email', '');
  v_ok  boolean;
begin
  if v_moi = '' then return false; end if;

  update public.ls_prescripteurs
     set compte_email  = v_moi,
         invite_jeton  = null,
         invite_expire = null
   where invite_jeton = p_jeton
     and p_jeton is not null and length(p_jeton) >= 20
     and (compte_email is null or compte_email = '' or compte_email = v_moi)
  returning true into v_ok;

  return coalesce(v_ok, false);
end $$;

grant execute on function public.ls_lier_compte(text) to authenticated;


select 'v3i posée' as etape,
       count(*) filter (where invite_jeton is not null
                          and coalesce(compte_email,'') = '') as invitations_ouvertes,
       count(*) filter (where coalesce(compte_email,'') <> '') as comptes_crees
  from public.ls_prescripteurs;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 36-schema-v3j.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3j : l'engrenage à partenaires
--
-- Recruter un partenaire est le seul appel dont l'effet ne s'arrête
-- pas quand on raccroche. Encore faut-il avoir qui appeler. Jusqu'ici
-- la file « Recruter des partenaires » attendait qu'on saisisse les
-- fiches à la main : elle est restée vide.
--
-- L'engrenage va chercher les bonnes entreprises dans le registre
-- public de l'État, filtrées par métier et par département. Gratuit,
-- ouvert, sans clé. Le registre ne publie pas les numéros de
-- téléphone : ils se complètent ensuite, fiche par fiche, et
-- seulement pour celles que le commercial garde.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

-- ─── 1. Ce que le registre nous apprend sur une fiche ──────────────

alter table public.ls_prescripteurs add column if not exists siren        text;
alter table public.ls_prescripteurs add column if not exists naf          text default '';
alter table public.ls_prescripteurs add column if not exists adresse      text default '';
alter table public.ls_prescripteurs add column if not exists code_postal  text default '';
alter table public.ls_prescripteurs add column if not exists ville        text default '';
alter table public.ls_prescripteurs add column if not exists effectif     text default '';
alter table public.ls_prescripteurs add column if not exists source       text default '';
alter table public.ls_prescripteurs add column if not exists cible_id     uuid;
alter table public.ls_prescripteurs add column if not exists tel_cherche_le timestamptz;

-- Le même SIREN ne rentre qu'une fois par maison. C'est ce qui permet
-- de relancer l'engrenage tous les matins sans dupliquer le fichier.
create unique index if not exists ls_presc_siren_idx
  on public.ls_prescripteurs (activite, siren) where siren is not null;

create index if not exists ls_presc_afaire_idx
  on public.ls_prescripteurs (activite, statut) where tel <> '';


-- ─── 2. Les métiers qu'on vise ─────────────────────────────────────
-- Un métier cible, c'est un code d'activité officiel et une raison de
-- l'appeler. La raison sert à l'accroche : elle s'affiche au
-- commercial au moment où il décroche.

create table if not exists public.ls_cibles (
  id         uuid primary key default gen_random_uuid(),
  activite   text not null check (activite in ('tiimizy','bornistes')),
  nom        text not null,
  naf        text not null,              -- code NAF, ex. 6920Z
  pourquoi   text default '',            -- l'accroche, en une phrase
  actif      boolean not null default true,
  trouves    integer not null default 0,
  dernier_le timestamptz,
  cree_le    timestamptz not null default now()
);
create unique index if not exists ls_cibles_naf_idx
  on public.ls_cibles (activite, naf);

alter table public.ls_cibles enable row level security;
drop policy if exists ls_cibles_equipe on public.ls_cibles;
create policy ls_cibles_equipe on public.ls_cibles
  for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());


-- ─── 3. Les métiers de départ ──────────────────────────────────────
-- Ils sont modifiables depuis l'engrenage. Ce ne sont que des points
-- de départ, semés par 56-oniq-amorcage.sql.


-- ─── 4. Où l'engrenage a cherché ───────────────────────────────────
-- Pour ne pas repasser deux fois sur le même département le même mois,
-- et pour savoir ce qui a déjà été ratissé.

create table if not exists public.ls_recherches (
  id          uuid primary key default gen_random_uuid(),
  activite    text not null,
  cible_id    uuid references public.ls_cibles(id) on delete set null,
  naf         text not null,
  departement text not null,
  trouves     integer not null default 0,
  crees       integer not null default 0,
  par         text default '',
  fait_le     timestamptz not null default now()
);
alter table public.ls_recherches enable row level security;
drop policy if exists ls_rech_equipe on public.ls_recherches;
create policy ls_rech_equipe on public.ls_recherches
  for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());


select 'v3j posée' as etape,
       (select count(*) from public.ls_cibles where activite='bornistes') as cibles_bornistes,
       (select count(*) from public.ls_cibles where activite='tiimizy')   as cibles_tiimizy;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 37-schema-v3k.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3k : deux adresses par personne, une par maison
--
-- Jusqu'ici l'adresse d'envoi se déduisait : on prenait la partie
-- avant le @ de l'adresse professionnelle et on la posait sur le
-- domaine de la maison du destinataire. Ça marche tant que les deux
-- adresses d'une personne ont le même identifiant. Le jour où
-- quelqu'un est p.nom@ d'un côté et prenom@ de l'autre, la déduction
-- se trompe en silence, et le client reçoit un message d'une adresse
-- qui n'existe pas.
--
-- On l'écrit donc noir sur blanc : deux colonnes, une par maison. La
-- déduction reste, en dernier recours, pour ceux qui n'ont rien
-- rempli.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

alter table public.ls_equipe add column if not exists mail_bornistes text default '';
alter table public.ls_equipe add column if not exists mail_tiimizy   text default '';

-- On amorce avec ce que la déduction produisait déjà : personne ne
-- voit son comportement changer, mais il devient lisible et modifiable.
update public.ls_equipe e
   set mail_bornistes = split_part(coalesce(nullif(e.repondre_a,''), e.email),'@',1)
                        || '@' || split_part(
                             (select valeur from public.ls_reglages
                               where cle='expediteur_email_bornistes'),'@',2)
 where coalesce(e.mail_bornistes,'') = ''
   and coalesce(split_part((select valeur from public.ls_reglages
                             where cle='expediteur_email_bornistes'),'@',2),'') <> '';

update public.ls_equipe e
   set mail_tiimizy = split_part(coalesce(nullif(e.repondre_a,''), e.email),'@',1)
                      || '@' || split_part(
                           (select valeur from public.ls_reglages
                             where cle='expediteur_email_tiimizy'),'@',2)
 where coalesce(e.mail_tiimizy,'') = ''
   and coalesce(split_part((select valeur from public.ls_reglages
                             where cle='expediteur_email_tiimizy'),'@',2),'') <> '';


-- ─── Ce que ça donne ───────────────────────────────────────────────
select nom,
       email          as se_connecte_avec,
       mail_bornistes as ecrit_aux_clients_bornistes,
       mail_tiimizy   as ecrit_aux_clients_tiimizy
  from public.ls_equipe
 order by nom;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 38-schema-v3l.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3l : l'engrenage rend des fiches appelables
--
-- Le registre public de l'État donne les entreprises mais aucun
-- téléphone : l'INSEE ne le collecte pas. Une fiche sans numéro ne
-- peut pas entrer dans une file d'appels, et l'engrenage produisait
-- donc des centaines de lignes inutilisables.
--
-- Deuxième source : l'annuaire ouvert d'OpenStreetMap. Il est
-- incomplet — il ne connaît que les établissements que quelqu'un a
-- pris la peine de cartographier — mais quand il connaît, il donne le
-- numéro, l'adresse et souvent le site. C'est libre, gratuit, et
-- explicitement réutilisable. On ne garde que les fiches avec un
-- numéro : mieux vaut trente entreprises qu'on peut appeler que trois
-- cents qu'on ne peut pas.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

-- Comment chaque métier se dit dans l'annuaire ouvert. Plusieurs
-- écritures possibles, séparées par des virgules. Les valeurs sont
-- posées avec chaque métier par 56-oniq-amorcage.sql.
alter table public.ls_cibles add column if not exists osm text default '';


-- L'origine de la fiche, pour savoir ce qu'on relit.
alter table public.ls_prescripteurs add column if not exists site text default '';

-- Le même numéro ne rentre qu'une fois par maison : c'est la seule
-- clé dont on dispose quand la fiche vient de l'annuaire ouvert, qui
-- ne connaît pas les SIREN.
create unique index if not exists ls_presc_tel_idx
  on public.ls_prescripteurs (activite, tel) where tel <> '';

select 'v3l posée' as etape, naf, nom, osm
  from public.ls_cibles order by activite, nom;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 39-schema-v3m.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3m : l'engrenage cherche aussi par l'enseigne
--
-- Vingt-deux experts-comptables dans le Rhône, c'est ce que donne la
-- cartographie quand on ne cherche que les établissements
-- proprement catégorisés. Beaucoup sont pourtant là, saisis à la
-- va-vite avec un simple nom. On ajoute donc un motif d'enseigne à
-- chaque métier : « comptab » attrape « Cabinet Durand expertise
-- comptable » même s'il n'a jamais reçu son étiquette de métier. Les
-- motifs d'ONIQ sont posés avec chaque métier par 56-oniq-amorcage.sql.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════


select naf, nom, osm from public.ls_cibles order by activite, nom;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 40-schema-v3n.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3n : une entreprise vue reste tranquille six mois
--
-- Rien n'abîme plus la réputation d'une équipe que deux commerciaux
-- qui appellent la même entreprise la même semaine. Jusqu'ici une
-- fiche ouverte mais non renseignée — l'appel n'aboutit pas, le
-- commercial passe à la suivante sans rien noter — revenait dans la
-- file le lendemain, et chez quelqu'un d'autre.
--
-- On date donc le moment où la fiche est passée devant quelqu'un, et
-- on la met au repos six mois. Deux exceptions, et deux seulement :
-- une promesse de rappel, qui doit toujours revenir, et une relance de
-- devis, qui n'est pas de la prospection.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

alter table public.ls_prescripteurs
  add column if not exists vu_le timestamptz not null default '1970-01-01';
alter table public.ls_prospects
  add column if not exists vu_le timestamptz not null default '1970-01-01';

-- Ce qui a déjà été appelé compte comme vu, à la date de l'appel.
update public.ls_prescripteurs
   set vu_le = dernier_appel
 where dernier_appel is not null and vu_le = '1970-01-01';

-- Les prospects n'ont pas de colonne « dernier appel » : leur dernière
-- trace est la date de mise à jour, qui bouge à chaque appel noté.
update public.ls_prospects
   set vu_le = updated_at
 where appel_resultat is not null
   and updated_at is not null
   and vu_le = '1970-01-01';

create index if not exists ls_presc_vu_idx   on public.ls_prescripteurs (vu_le);
create index if not exists ls_prosp_vu_idx   on public.ls_prospects (vu_le);


-- ─── Les doublons déjà présents ────────────────────────────────────
-- L'engrenage a pu créer deux fois la même enseigne sous deux
-- orthographes, ou depuis deux sources. On garde la plus ancienne,
-- celle qui porte l'historique, et seulement parmi les fiches de
-- prospection jamais appelées : on ne touche à aucune relation.

with rangs as (
  select id,
         row_number() over (
           partition by activite, lower(regexp_replace(nom, '[^a-zA-Z0-9]', '', 'g'))
           order by cree_le asc
         ) as r
    from public.ls_prescripteurs
   where source in ('registre','annuaire')
     and appel_resultat is null
     and coalesce(compte_email,'') = ''
     and coalesce(contrat_statut,'aucun') = 'aucun'
)
delete from public.ls_prescripteurs p
 using rangs
 where p.id = rangs.id and rangs.r > 1;


select 'v3n posée' as etape,
       (select count(*) from public.ls_prescripteurs) as fiches_partenaires,
       (select count(*) from public.ls_prescripteurs
         where vu_le > now() - interval '6 months') as au_repos_six_mois;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 41-schema-v3o.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3o : l'engrenage lit aussi l'e-mail et le dirigeant
--
-- Une page contact donne le téléphone ; une page « mentions légales »
-- donne le nom du directeur de la publication, c'est-à-dire le patron,
-- et souvent son adresse. On note désormais quand un site a été lu,
-- indépendamment du téléphone, pour pouvoir y revenir chercher
-- l'e-mail sur les fiches qui avaient déjà un numéro.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

alter table public.ls_prescripteurs add column if not exists site_lu_le timestamptz;
alter table public.ls_prescripteurs add column if not exists email_origine text default '';

-- Les fiches dont le site a déjà servi à trouver le numéro repartent
-- pour une lecture : la première passe ne cherchait pas l'e-mail.
update public.ls_prescripteurs
   set site_lu_le = null
 where coalesce(site,'') <> '' and coalesce(email,'') = '';

select 'v3o posée' as etape,
       count(*) filter (where coalesce(site,'') <> '' and coalesce(email,'') = '') as sites_a_relire
  from public.ls_prescripteurs;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 42-schema-v3p.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3p : ce que la base refuse, la page n'a plus à le
-- promettre
--
-- Un audit a relu toutes les portes. Plusieurs laissaient passer un
-- compte « aucun » (connecté, mais ni équipe ni partenaire), et rien
-- ne séparait la direction du commercial : n'importe quel membre
-- pouvait se promouvoir, couper un collègue, réécrire les réglages.
--
-- Cinq chantiers :
--   1. les tables où « pas partenaire » voulait dire « tout le monde »
--   2. direction / commercial : qui règle la maison, qui la fait tourner
--   3. le stockage : les devis ne sont pas des plaquettes
--   4. les abonnements push : un partenaire n'en pose que pour lui
--   5. la file d'envoi : un message ne part qu'une fois, même si deux
--      moteurs tournent en même temps
--
-- À déployer AVANT la nouvelle version du moteur : il lit la colonne
-- adresse_norm et pose le statut en_cours, qui n'existent qu'ici.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 1. « Pas partenaire » n'a jamais voulu dire « tout le monde » ──

-- ls_mon_role() rend aussi 'aucun' : un compte créé librement et
-- rattaché à rien. Tester « <> 'partenaire' » le laissait entrer. On
-- nomme désormais ce qu'on autorise, jamais ce qu'on refuse.

drop policy if exists partenaire_voit_ses_leads on public.ls_prospects;
create policy partenaire_voit_ses_leads on public.ls_prospects
  for select to authenticated
  using (
    public.ls_est_staff()
    or (public.ls_mon_role() = 'partenaire'
        and partenaire_id = public.ls_mon_partenaire())
  );

-- La bibliothèque : lecture et dépôt réservés à l'équipe. Les
-- documents restent lisibles par leur adresse publique, c'est le
-- catalogue de la bibliothèque qui n'est plus offert à tout venant.
drop policy if exists equipe_all on public.ls_documents;
create policy equipe_all on public.ls_documents for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());

-- Le journal des tirages : « using (true) » l'ouvrait aux partenaires
-- et aux inconnus. Il ne raconte que la vie interne des leads.
drop policy if exists equipe_lit on public.ls_tirages;
create policy equipe_lit on public.ls_tirages for select to authenticated
  using (public.ls_est_staff());

-- Le catalogue : les prix se lisent par l'équipe et, si le portail en
-- a besoin un jour, par un partenaire connu. Ils ne se changent que
-- par l'équipe — un tarif modifiable par n'importe quel compte
-- connecté, c'est un devis faux qui part chez un client.
drop policy if exists ls_catalogue_lecture on public.ls_catalogue;
create policy ls_catalogue_lecture on public.ls_catalogue
  for select to authenticated
  using (public.ls_est_staff() or public.ls_mon_role() = 'partenaire');
drop policy if exists ls_catalogue_ecriture on public.ls_catalogue;
create policy ls_catalogue_ecriture on public.ls_catalogue
  for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());


-- ─── 2. La direction règle la maison, le commercial la fait tourner ─

-- Même mécanique que ls_est_staff() : la base décide d'après l'équipe,
-- pas d'après ce que la page croit. L'amorçage est conservé : tant que
-- l'équipe est vide, la première personne connectée est la direction,
-- sinon personne ne pourrait jamais créer la première fiche.
create or replace function public.ls_est_direction()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
           select 1 from public.ls_equipe
            where lower(btrim(email)) = lower(btrim(coalesce(auth.jwt() ->> 'email','')))
              and role = 'direction' and actif)
      or not exists (select 1 from public.ls_equipe);
$$;
grant execute on function public.ls_est_direction() to authenticated;
grant execute on function public.ls_est_staff()     to authenticated;

-- Les tables de réglage : tout le monde les lit, la direction seule
-- les écrit. Une règle d'envoi allumée par erreur ou une opposition
-- retirée, c'est un client qui reçoit ce qu'il a refusé.
do $$
declare t text;
begin
  foreach t in array array['ls_reglages','ls_regles','ls_desinscrits']
  loop
    execute format('drop policy if exists equipe_all on public.%I', t);
    execute format('drop policy if exists equipe_lit on public.%I', t);
    execute format('drop policy if exists direction_pose on public.%I', t);
    execute format('drop policy if exists direction_maj on public.%I', t);
    execute format('drop policy if exists direction_suppr on public.%I', t);
    execute format('create policy equipe_lit on public.%I for select to authenticated using (public.ls_est_staff())', t);
    execute format('create policy direction_pose on public.%I for insert to authenticated with check (public.ls_est_direction())', t);
    execute format('create policy direction_maj on public.%I for update to authenticated using (public.ls_est_direction()) with check (public.ls_est_direction())', t);
    execute format('create policy direction_suppr on public.%I for delete to authenticated using (public.ls_est_direction())', t);
  end loop;
end $$;

-- L'équipe : la direction fait tout ; un membre ne touche qu'à sa
-- propre ligne, et pas à son rôle ni à son accès. La politique ouvre
-- la ligne, le déclencheur garde les deux colonnes : une politique
-- ne sait pas dire « cette colonne-là, non ».
drop policy if exists equipe_all      on public.ls_equipe;
drop policy if exists equipe_lit      on public.ls_equipe;
drop policy if exists direction_pose  on public.ls_equipe;
drop policy if exists direction_maj   on public.ls_equipe;
drop policy if exists direction_suppr on public.ls_equipe;
drop policy if exists moi_maj         on public.ls_equipe;
create policy equipe_lit on public.ls_equipe for select to authenticated
  using (public.ls_est_staff());
create policy direction_pose on public.ls_equipe for insert to authenticated
  with check (public.ls_est_direction());
create policy direction_maj on public.ls_equipe for update to authenticated
  using (public.ls_est_direction()) with check (public.ls_est_direction());
create policy direction_suppr on public.ls_equipe for delete to authenticated
  using (public.ls_est_direction());
create policy moi_maj on public.ls_equipe for update to authenticated
  using      (lower(email) = lower(coalesce(auth.jwt() ->> 'email','')))
  with check (lower(email) = lower(coalesce(auth.jwt() ->> 'email','')));

-- Le garde-fou ne joue que pour un utilisateur connecté par l'API.
-- L'éditeur SQL et les fonctions Edge (clé service) n'ont pas de JWT :
-- les bloquer empêcherait la direction de se corriger depuis Supabase.
-- L'adresse est verrouillée avec le rôle : c'est la clé de la ligne,
-- la changer reviendrait à se faire passer pour quelqu'un d'autre.
create or replace function public.ls_equipe_garde()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(),'') = 'authenticated' and not public.ls_est_direction() then
    new.role    := old.role;
    new.actif   := old.actif;
    new.email   := old.email;
    new.cree_le := old.cree_le;
  end if;
  return new;
end $$;
drop trigger if exists ls_equipe_garde on public.ls_equipe;
create trigger ls_equipe_garde before update on public.ls_equipe
  for each row execute function public.ls_equipe_garde();

-- Une adresse, une ligne. Prenom@ et prenom@ étaient deux membres pour
-- la clé primaire et un seul pour ls_mon_role() : le second n'avait
-- jamais ni nom ni signature. On garde la plus ancienne, on n'efface
-- que les coquilles vides — une ligne renseignée se tranche à la main.
delete from public.ls_equipe e
 using (select email,
               row_number() over (partition by lower(email) order by cree_le, email) as rang
          from public.ls_equipe) d
 where d.email = e.email and d.rang > 1
   and coalesce(e.nom,'') = '' and coalesce(e.repondre_a,'') = '';

do $$
begin
  create unique index if not exists ls_equipe_email_unique_idx
    on public.ls_equipe (lower(email));
exception when unique_violation then
  raise warning 'ls_equipe : des doublons renseignés subsistent (%), l''index unique n''est pas posé. À trancher à la main.',
    (select string_agg(lower(email), ', ') from
       (select lower(email) as email from public.ls_equipe group by lower(email) having count(*) > 1) x);
end $$;


-- ─── 3. Le stockage : une plaquette se donne, un devis se montre ────

-- Le seau « documents » reste public : ses fichiers sont faits pour
-- être lus par des clients sans compte, par leur adresse directe. La
-- lecture par adresse ne passe pas par ces politiques ; seule la
-- liste des objets et leur dépôt en dépendent, et ça, c'est l'équipe.
drop policy if exists documents_lecture on storage.objects;
create policy documents_lecture on storage.objects for select to authenticated
  using (bucket_id = 'documents' and public.ls_est_staff());

drop policy if exists documents_depot on storage.objects;
create policy documents_depot on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and public.ls_est_staff());

drop policy if exists documents_maj on storage.objects;
create policy documents_maj on storage.objects for update to authenticated
  using (bucket_id = 'documents' and public.ls_est_staff())
  with check (bucket_id = 'documents' and public.ls_est_staff());

drop policy if exists documents_suppr on storage.objects;
create policy documents_suppr on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and public.ls_est_staff());

-- Un devis porte le nom, l'adresse et le prix d'un client : il n'a
-- rien à faire dans un seau public où une adresse devinée suffit à le
-- lire. Le seau « devis » est privé ; l'équipe y dépose et y lit, un
-- partenaire n'y a aucune politique, donc aucun droit.
--
-- À FAIRE CÔTÉ PAGE (hors de cette migration) : déposer les devis dans
-- 'devis' et non plus dans 'documents', et les servir par une URL
-- signée (storage/v1/object/sign/devis/…) plutôt que par l'adresse
-- publique.
insert into storage.buckets (id, name, public)
values ('devis', 'devis', false)
on conflict (id) do nothing;

drop policy if exists devis_lecture on storage.objects;
create policy devis_lecture on storage.objects for select to authenticated
  using (bucket_id = 'devis' and public.ls_est_staff());

drop policy if exists devis_depot on storage.objects;
create policy devis_depot on storage.objects for insert to authenticated
  with check (bucket_id = 'devis' and public.ls_est_staff());

drop policy if exists devis_maj on storage.objects;
create policy devis_maj on storage.objects for update to authenticated
  using (bucket_id = 'devis' and public.ls_est_staff())
  with check (bucket_id = 'devis' and public.ls_est_staff());

drop policy if exists devis_suppr on storage.objects;
create policy devis_suppr on storage.objects for delete to authenticated
  using (bucket_id = 'devis' and public.ls_est_staff());


-- ─── 4. Les abonnements push : les siens, et seulement les siens ────

-- L'adresse ne suffisait pas : un partenaire pouvait inscrire un
-- appareil au nom de son adresse mais sur l'identifiant d'un autre
-- partenaire, et recevoir ses notifications.
drop policy if exists ls_push_sien on public.ls_push;
create policy ls_push_sien on public.ls_push
  for all to authenticated
  using  (lower(email) = lower(coalesce(auth.jwt() ->> 'email',''))
          and (partenaire_id is null or partenaire_id = public.ls_mon_partenaire()))
  with check (lower(email) = lower(coalesce(auth.jwt() ->> 'email',''))
          and (partenaire_id is null or partenaire_id = public.ls_mon_partenaire()));


-- ─── 5. La file d'envoi : un message part une fois ─────────────────

-- Deux passages du moteur qui se chevauchent lisaient la même ligne
-- « en attente » et l'envoyaient deux fois. Le moteur réserve
-- désormais la ligne (en_attente → en_cours) par une écriture
-- conditionnelle avant d'envoyer : une seule des deux y arrive.
-- pris_le dit depuis quand ; passé quinze minutes, la ligne a été
-- oubliée par un moteur coupé en route et le suivant la reprend.
alter table public.ls_envois add column if not exists pris_le timestamptz;

alter table public.ls_envois drop constraint if exists ls_envois_statut_check;
alter table public.ls_envois add constraint ls_envois_statut_check
  check (statut in ('en_attente','en_cours','envoye','echec','annule')) not valid;
-- Les lignes déjà là sont vérifiées à part : une valeur inattendue
-- d'un ancien passage ne doit pas faire échouer toute la migration.
do $$
begin
  alter table public.ls_envois validate constraint ls_envois_statut_check;
exception when check_violation then
  raise warning 'ls_envois : des statuts inconnus subsistent, la contrainte reste « not valid ». select distinct statut from ls_envois pour les voir.';
end $$;


-- ─── 6. L'opposition qui compare des numéros, pas des graphies ──────

-- « +33 6 12 34 56 78 » et « 0612345678 » sont le même téléphone, et
-- la liste d'opposition les tenait pour deux adresses différentes : un
-- STOP par SMS ne bloquait pas le numéro écrit autrement. On garde
-- l'adresse telle que saisie, et on compare sur une forme unique que
-- la base calcule elle-même. Le moteur applique la même règle, mot
-- pour mot, avant de comparer.
create or replace function public.ls_tel_norm(t text)
returns text language sql immutable strict parallel safe as $$
  select case
           when t ~ '^\s*\+33' then '0' || regexp_replace(regexp_replace(t, '^\s*\+33\s*(\(0\))?', ''), '[^0-9]', '', 'g')
           else regexp_replace(t, '[^0-9]', '', 'g')
         end;
$$;

alter table public.ls_desinscrits add column if not exists adresse_norm text
  generated always as (
    case when canal = 'sms' then public.ls_tel_norm(adresse) else lower(btrim(adresse)) end
  ) stored;
create index if not exists ls_desinscrits_norm_idx on public.ls_desinscrits (adresse_norm);


select 'v3p posée' as etape,
       (select count(*) from pg_policies where schemaname = 'public' and tablename = 'ls_equipe') as politiques_equipe,
       (select count(*) from pg_policies where schemaname = 'storage' and policyname like 'devis_%') as politiques_devis,
       (select exists (select 1 from storage.buckets where id = 'devis')) as seau_devis,
       (select count(*) from public.ls_envois where statut = 'en_cours') as envois_en_cours,
       (select count(*) from public.ls_desinscrits where adresse_norm is not null) as oppositions_normalisees;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 43-schema-v3q.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3q : le partenaire transmet un contact depuis son espace
--
-- C'est la raison d'être de l'espace partenaire, et il ne le permettait
-- pas : « transmettez-nous un contact par téléphone ». Un partenaire
-- peut maintenant créer un lead, rattaché à lui, et rien d'autre : il
-- ne lit et ne modifie toujours que ce qui lui appartient.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

drop policy if exists partenaire_transmet on public.ls_prospects;
create policy partenaire_transmet on public.ls_prospects
  for insert to authenticated
  with check (
    public.ls_mon_role() = 'partenaire'
    and partenaire_id = public.ls_mon_partenaire()
    and coalesce(est_lead, false) = true
    and source = 'partenaire'
  );

-- Le journal accepte une trace signée d'un partenaire, pour que
-- l'équipe voie d'où vient le contact.
do $$
begin
  if exists (select 1 from pg_tables where schemaname='public' and tablename='ls_activite') then
    execute 'drop policy if exists partenaire_trace on public.ls_activite';
    execute 'create policy partenaire_trace on public.ls_activite for insert to authenticated with check (public.ls_mon_role() = ''partenaire'')';
  end if;
end $$;

select 'v3q posée' as etape,
       (select count(*) from pg_policies where tablename='ls_prospects' and policyname='partenaire_transmet') as policy_posee;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 44-schema-v3r.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3r : retiré pour ONIQ
--
-- Ce bloc réorientait les métiers cibles de l'ancienne activité. Il ne
-- contient plus rien : les métiers visés par ONIQ, clients et
-- prescripteurs, sont semés par 56-oniq-amorcage.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 45-schema-v3s.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3s : les campagnes de mailing
--
-- Une campagne, c'est un message, une audience, et un rythme. Elle
-- n'a pas son propre moteur : elle dépose ses messages dans la même
-- file que tout le reste, échelonnés dans le temps, et le moteur
-- d'envoi fait ce qu'il fait déjà : les heures ouvrées, la liste
-- d'opposition, le plafond du jour, les reprises. Une seule porte de
-- sortie pour tous les messages, c'est une seule à surveiller.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.ls_campagnes (
  id            uuid primary key default gen_random_uuid(),
  nom           text not null,
  activite      text not null check (activite in ('tiimizy','bornistes')),
  canal         text not null default 'email' check (canal in ('email')),
  objet         text not null default '',
  corps         text not null default '',
  cible         jsonb not null default '{}'::jsonb,   -- la définition de l'audience
  nb_cibles     integer not null default 0,           -- combien au moment du lancement
  statut        text not null default 'brouillon'
                check (statut in ('brouillon','programmee','en_cours','terminee','annulee')),
  debut_le      timestamptz,
  cadence_h     integer not null default 40,          -- messages par heure
  owner_email   text default '',
  test_envoye_le timestamptz,
  lance_le      timestamptz,
  cree_le       timestamptz not null default now(),
  maj_le        timestamptz not null default now()
);

alter table public.ls_envois add column if not exists campagne_id uuid
  references public.ls_campagnes(id) on delete set null;
create index if not exists ls_envois_campagne_idx on public.ls_envois (campagne_id, statut);

alter table public.ls_campagnes enable row level security;
drop policy if exists ls_campagnes_equipe on public.ls_campagnes;
create policy ls_campagnes_equipe on public.ls_campagnes
  for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());

-- Les compteurs d'une campagne, calculés à la demande depuis la file.
-- Pas de colonnes à tenir à jour : la file est la vérité.
-- v3w la remplace par une version plus large ; le drop permet de
-- rejouer ce bloc après elle sans buter sur la forme du résultat.
drop function if exists public.ls_campagne_bilan(uuid);
create or replace function public.ls_campagne_bilan(p_id uuid)
returns table (en_attente bigint, en_cours bigint, envoyes bigint, echecs bigint, annules bigint)
language sql stable security definer set search_path = public as $$
  select count(*) filter (where statut = 'en_attente'),
         count(*) filter (where statut = 'en_cours'),
         count(*) filter (where statut = 'envoye'),
         count(*) filter (where statut = 'echec'),
         count(*) filter (where statut = 'annule')
    from public.ls_envois where campagne_id = p_id;
$$;
grant execute on function public.ls_campagne_bilan(uuid) to authenticated;

-- Annuler ce qui n'est pas parti. Ce qui est parti est parti.
create or replace function public.ls_campagne_annuler(p_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.ls_est_staff() then raise exception 'réservé à l''équipe'; end if;
  update public.ls_envois set statut = 'annule'
   where campagne_id = p_id and statut in ('en_attente');
  get diagnostics n = row_count;
  update public.ls_campagnes set statut = 'annulee', maj_le = now() where id = p_id;
  return n;
end $$;
grant execute on function public.ls_campagne_annuler(uuid) to authenticated;

-- Quand tout est parti, la campagne se marque terminée d'elle-même.
create or replace function public.ls_campagnes_maj_statut()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.campagne_id is not null and new.statut in ('envoye','echec','annule') then
    update public.ls_campagnes c set statut = 'terminee', maj_le = now()
     where c.id = new.campagne_id and c.statut in ('programmee','en_cours')
       and not exists (select 1 from public.ls_envois e
                        where e.campagne_id = c.id and e.statut in ('en_attente','en_cours'));
    update public.ls_campagnes c set statut = 'en_cours', maj_le = now()
     where c.id = new.campagne_id and c.statut = 'programmee' and new.statut = 'envoye';
  end if;
  return new;
end $$;
drop trigger if exists ls_campagnes_suivi on public.ls_envois;
create trigger ls_campagnes_suivi after update of statut on public.ls_envois
  for each row execute function public.ls_campagnes_maj_statut();

select 'v3s posée' as etape,
       (select count(*) from public.ls_campagnes) as campagnes;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 46-schema-v3t.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3t : retiré pour ONIQ
--
-- Ce bloc tarifait un article de l'ancien catalogue. Il ne contient plus
-- rien : le catalogue d'ONIQ est semé par 56-oniq-amorcage.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 47-schema-v3u.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3u : retiré pour ONIQ
--
-- Ce bloc activait et désactivait des articles de l'ancien catalogue. Il
-- ne contient plus rien : le catalogue d'ONIQ est semé par
-- 56-oniq-amorcage.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 48-schema-v3v.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3v : retiré pour ONIQ
--
-- Ce bloc annulait v3u sur l'ancien catalogue. Il ne contient plus
-- rien : le catalogue d'ONIQ est semé par 56-oniq-amorcage.sql.
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 49-schema-v3w.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — v3w : les campagnes, version délivrabilité
--
-- Ce que cette mise à jour ajoute :
--   1. Les boîtes d'envoi (ls_boites) : une adresse, une maison, une
--      date de mise en service. Le plafond du jour se calcule tout
--      seul depuis cette date, personne ne le règle à la main.
--   2. Les séquences (ls_sequences) : un contact, une campagne, trois
--      mails. Chaque contact avance dans la sienne.
--   3. Les retours (ls_retours) : ce que Brevo nous renvoie, livré,
--      rebondi, plainte, désabonné. C'est de là que viennent les taux.
--   4. Les sorties : répondu, désabonné, invalide, avec l'étiquette
--      posée sur la fiche pour que le commercial la voie en appel.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

-- ── 0. Une colonne de v3f qui manquait en production ───────────────
alter table public.ls_devis add column if not exists pdf_url text default '';

-- ── 1. Les boîtes d'envoi ──────────────────────────────────────────
create table if not exists public.ls_boites (
  id                 uuid primary key default gen_random_uuid(),
  adresse            text not null,
  activite           text not null check (activite in ('tiimizy','bornistes')),
  nom_expediteur     text not null default '',
  proprietaire_email text default '',        -- le commercial dont c'est la boîte
  mise_en_service_le date not null default current_date,
  actif              boolean not null default true,
  note               text default '',
  cree_le            timestamptz not null default now(),
  maj_le             timestamptz not null default now()
);
-- L'adresse qui envoie n'est pas celle qui reçoit : on écrit depuis le
-- sous-domaine d'envoi (prenom@mail.oniq.online), la réponse arrive
-- dans la vraie boîte (prenom@oniq.online). Le domaine principal ne
-- porte jamais la réputation d'une campagne.
alter table public.ls_boites add column if not exists adresse_envoi text not null default '';
create unique index if not exists ls_boites_adresse_idx on public.ls_boites (lower(adresse));

alter table public.ls_boites enable row level security;
drop policy if exists ls_boites_equipe on public.ls_boites;
create policy ls_boites_equipe on public.ls_boites
  for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());

-- Le plafond du jour d'une boîte ne dépend que de son âge :
-- 15 les trois premiers jours, 25 jusqu'au septième, 40 jusqu'au
-- quatorzième, 50 ensuite. Jamais plus de 50 en prospection froide.
create or replace function public.ls_boite_plafond(p_depuis date, p_jour date default current_date)
returns integer language sql immutable as $$
  select case
    when p_jour - p_depuis < 3  then 15
    when p_jour - p_depuis < 7  then 25
    when p_jour - p_depuis < 14 then 40
    else 50 end;
$$;
-- Une boîte est prête à partir de son quinzième jour.
create or replace function public.ls_boite_etat(p_depuis date, p_jour date default current_date)
returns text language sql immutable as $$
  select case when p_jour - p_depuis >= 14 then 'prete' else 'chauffe' end;
$$;

-- ── 2. La file d'envoi apprend la boîte et la séquence ─────────────
alter table public.ls_envois add column if not exists boite_id uuid
  references public.ls_boites(id) on delete set null;
alter table public.ls_envois add column if not exists sequence_id uuid;
alter table public.ls_envois add column if not exists etape_seq smallint not null default 1;
alter table public.ls_envois add column if not exists message_id text;
alter table public.ls_envois add column if not exists livre_le timestamptz;
alter table public.ls_envois add column if not exists rebond_le timestamptz;
alter table public.ls_envois add column if not exists rebond_type text default '';
alter table public.ls_envois add column if not exists plainte_le timestamptz;
create index if not exists ls_envois_boite_idx on public.ls_envois (boite_id, envoye_le desc);
create index if not exists ls_envois_message_idx on public.ls_envois (message_id);
create index if not exists ls_envois_sequence_idx on public.ls_envois (sequence_id);

-- ── 3. Les campagnes : trois mails, un jeu de boîtes, un rythme ────
alter table public.ls_campagnes add column if not exists boites uuid[] not null default '{}';
alter table public.ls_campagnes add column if not exists objet2 text not null default '';
alter table public.ls_campagnes add column if not exists corps2 text not null default '';
alter table public.ls_campagnes add column if not exists objet3 text not null default '';
alter table public.ls_campagnes add column if not exists corps3 text not null default '';
alter table public.ls_campagnes add column if not exists delai2 integer not null default 8;
alter table public.ls_campagnes add column if not exists delai3 integer not null default 18;
alter table public.ls_campagnes add column if not exists espacement_min integer not null default 90;
alter table public.ls_campagnes add column if not exists espacement_max integer not null default 400;
alter table public.ls_campagnes add column if not exists signature text not null default '';
-- L'habillage des mails : texte seul, signature maison (par défaut) ou
-- charte complète. Le choix décide de l'onglet où le message atterrit.
alter table public.ls_campagnes add column if not exists habillage text not null default 'maison';
alter table public.ls_campagnes drop constraint if exists ls_campagnes_habillage_chk;
alter table public.ls_campagnes add constraint ls_campagnes_habillage_chk
  check (habillage in ('sobre','maison','charte'));
-- Une campagne peut se mettre en pause : rien ne part, les séquences
-- attendent, et tout repart d'un clic.
alter table public.ls_campagnes drop constraint if exists ls_campagnes_statut_check;
alter table public.ls_campagnes add constraint ls_campagnes_statut_check
  check (statut in ('brouillon','programmee','en_cours','en_pause','terminee','annulee'));
alter table public.ls_campagnes alter column cadence_h set default 12;
update public.ls_campagnes set cadence_h = 12 where cadence_h > 20 or cadence_h < 1;
alter table public.ls_campagnes drop constraint if exists ls_campagnes_cadence_chk;
alter table public.ls_campagnes add constraint ls_campagnes_cadence_chk check (cadence_h between 1 and 20);

-- ── 4. Les séquences ───────────────────────────────────────────────
create table if not exists public.ls_sequences (
  id            uuid primary key default gen_random_uuid(),
  campagne_id   uuid not null references public.ls_campagnes(id) on delete cascade,
  email         text not null,
  prospect_id   uuid references public.ls_prospects(id) on delete set null,
  partenaire_id uuid references public.ls_prescripteurs(id) on delete set null,
  boite_id      uuid references public.ls_boites(id) on delete set null,
  societe       text default '',
  dirigeant     text default '',
  ville         text default '',
  activite      text default '',
  etape         smallint not null default 0,      -- dernier mail parti : 0, 1, 2, 3
  statut        text not null default 'en_cours'
                check (statut in ('en_cours','repondu','desinscrit','rebond','termine','arrete')),
  sortie        text not null default '',         -- mail | appel | stop | plainte | rebond | fin
  prochain_le   timestamptz,                      -- quand poser le mail suivant
  mail1_le      timestamptz,
  mail2_le      timestamptz,
  mail3_le      timestamptz,
  sorti_le      timestamptz,
  rebonds       integer not null default 0,
  cree_le       timestamptz not null default now(),
  maj_le        timestamptz not null default now(),
  unique (campagne_id, email)
);
create index if not exists ls_sequences_suite_idx on public.ls_sequences (statut, prochain_le);
create index if not exists ls_sequences_email_idx on public.ls_sequences (lower(email));

alter table public.ls_sequences enable row level security;
drop policy if exists ls_sequences_equipe on public.ls_sequences;
create policy ls_sequences_equipe on public.ls_sequences
  for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());

-- ── 5. Les retours de Brevo ────────────────────────────────────────
create table if not exists public.ls_retours (
  id          uuid primary key default gen_random_uuid(),
  evenement   text not null,                     -- livre | rebond_dur | rebond_doux | bloque | plainte | desabonne | reponse | autre
  email       text default '',
  message_id  text default '',
  envoi_id    uuid references public.ls_envois(id) on delete set null,
  boite_id    uuid references public.ls_boites(id) on delete set null,
  campagne_id uuid references public.ls_campagnes(id) on delete set null,
  motif       text default '',
  brut        jsonb,
  recu_le     timestamptz not null default now()
);
create index if not exists ls_retours_boite_idx on public.ls_retours (boite_id, recu_le desc);
create index if not exists ls_retours_camp_idx on public.ls_retours (campagne_id, evenement);
alter table public.ls_retours enable row level security;
drop policy if exists ls_retours_lecture on public.ls_retours;
create policy ls_retours_lecture on public.ls_retours
  for select to authenticated using (public.ls_est_staff());

-- ── 6. Les fiches apprennent l'étiquette et l'adresse invalide ─────
alter table public.ls_prescripteurs add column if not exists email_invalide boolean not null default false;
alter table public.ls_prescripteurs add column if not exists campagne_etiquette text default '';
alter table public.ls_prescripteurs add column if not exists campagne_repondu_id uuid;
alter table public.ls_prospects add column if not exists email_invalide boolean not null default false;
alter table public.ls_prospects add column if not exists campagne_etiquette text default '';
alter table public.ls_prospects add column if not exists campagne_repondu_id uuid;

-- ── 7. Le bilan d'une boîte : plafond, état, compteur, taux ────────
-- Le drop précède la création : il permet de changer la forme du
-- résultat quand on rejoue, sans faire disparaître la fonction.
drop function if exists public.ls_boites_bilan();
create or replace function public.ls_boites_bilan()
returns table (
  id uuid, adresse text, adresse_envoi text, activite text, nom_expediteur text, proprietaire_email text,
  mise_en_service_le date, actif boolean, note text,
  plafond integer, etat text, jours integer,
  envoyes_jour bigint, envoyes_30j bigint, rebonds_30j bigint, plaintes_30j bigint,
  taux_rebond numeric, taux_plainte numeric
)
language sql stable security definer set search_path = public as $$
  with e as (
    select boite_id,
           count(*) filter (where statut = 'envoye' and envoye_le >= date_trunc('day', now())) as jour,
           count(*) filter (where statut = 'envoye' and envoye_le >= now() - interval '30 days') as mois
      from public.ls_envois where boite_id is not null group by boite_id),
  r as (
    select boite_id,
           count(*) filter (where evenement in ('rebond_dur','rebond_doux','bloque') and recu_le >= now() - interval '30 days') as rebonds,
           count(*) filter (where evenement = 'plainte' and recu_le >= now() - interval '30 days') as plaintes
      from public.ls_retours where boite_id is not null group by boite_id)
  select b.id, b.adresse, b.adresse_envoi, b.activite, b.nom_expediteur, b.proprietaire_email,
         b.mise_en_service_le, b.actif, b.note,
         public.ls_boite_plafond(b.mise_en_service_le) as plafond,
         public.ls_boite_etat(b.mise_en_service_le) as etat,
         (current_date - b.mise_en_service_le)::integer as jours,
         coalesce(e.jour,0), coalesce(e.mois,0), coalesce(r.rebonds,0), coalesce(r.plaintes,0),
         case when coalesce(e.mois,0) = 0 then 0 else round(100.0 * coalesce(r.rebonds,0) / e.mois, 2) end,
         case when coalesce(e.mois,0) = 0 then 0 else round(100.0 * coalesce(r.plaintes,0) / e.mois, 2) end
    from public.ls_boites b
    left join e on e.boite_id = b.id
    left join r on r.boite_id = b.id
   where public.ls_est_staff()
   order by b.activite, b.adresse;
$$;
grant execute on function public.ls_boites_bilan() to authenticated;

-- ── 8. Le bilan d'une campagne, séquences comprises ────────────────
drop function if exists public.ls_campagne_bilan(uuid);
create or replace function public.ls_campagne_bilan(p_id uuid)
returns table (
  contacts bigint, en_sequence bigint,
  en_attente bigint, en_cours bigint, envoyes bigint, echecs bigint, annules bigint,
  envoyes1 bigint, envoyes2 bigint, envoyes3 bigint,
  livres bigint, rebondis bigint, plaintes bigint,
  repondus bigint, appels_entrants bigint, desinscrits bigint, invalides bigint,
  taux_reponse numeric
)
language sql stable security definer set search_path = public as $$
  with s as (
    select count(*) as contacts,
           count(*) filter (where statut = 'en_cours') as en_sequence,
           count(*) filter (where statut = 'repondu') as repondus,
           count(*) filter (where statut = 'repondu' and sortie = 'appel') as appels,
           count(*) filter (where statut = 'desinscrit') as desinscrits,
           count(*) filter (where statut = 'rebond') as invalides,
           count(*) filter (where etape >= 1) as touches
      from public.ls_sequences where campagne_id = p_id),
  e as (
    select count(*) filter (where statut = 'en_attente') as att,
           count(*) filter (where statut = 'en_cours') as enc,
           count(*) filter (where statut = 'envoye') as env,
           count(*) filter (where statut = 'echec') as ech,
           count(*) filter (where statut = 'annule') as ann,
           count(*) filter (where statut = 'envoye' and etape_seq = 1) as e1,
           count(*) filter (where statut = 'envoye' and etape_seq = 2) as e2,
           count(*) filter (where statut = 'envoye' and etape_seq = 3) as e3,
           count(*) filter (where livre_le is not null) as liv,
           count(*) filter (where rebond_le is not null) as reb,
           count(*) filter (where plainte_le is not null) as pla
      from public.ls_envois where campagne_id = p_id)
  select s.contacts, s.en_sequence, e.att, e.enc, e.env, e.ech, e.ann, e.e1, e.e2, e.e3,
         e.liv, e.reb, e.pla, s.repondus, s.appels, s.desinscrits, s.invalides,
         case when s.touches = 0 then 0 else round(100.0 * s.repondus / s.touches, 1) end
    from s, e;
$$;
grant execute on function public.ls_campagne_bilan(uuid) to authenticated;

-- ── 9. Une séquence avance quand son mail part ─────────────────────
create or replace function public.ls_sequences_avance()
returns trigger language plpgsql security definer set search_path = public as $$
declare c record;
begin
  if new.sequence_id is null or new.statut <> 'envoye' then return new; end if;
  select delai2, delai3, corps2, corps3 into c from public.ls_campagnes where id = new.campagne_id;
  update public.ls_sequences s set
    etape = greatest(s.etape, new.etape_seq),
    mail1_le = case when new.etape_seq = 1 then coalesce(s.mail1_le, new.envoye_le) else s.mail1_le end,
    mail2_le = case when new.etape_seq = 2 then coalesce(s.mail2_le, new.envoye_le) else s.mail2_le end,
    mail3_le = case when new.etape_seq = 3 then coalesce(s.mail3_le, new.envoye_le) else s.mail3_le end,
    prochain_le = case
      when new.etape_seq = 1 and coalesce(c.corps2,'') <> '' then new.envoye_le + make_interval(days => coalesce(c.delai2,8))
      when new.etape_seq = 2 and coalesce(c.corps3,'') <> '' then new.envoye_le + make_interval(days => greatest(1, coalesce(c.delai3,18) - coalesce(c.delai2,8)))
      else null end,
    statut = case
      when s.statut <> 'en_cours' then s.statut
      when new.etape_seq = 3 then 'termine'
      when new.etape_seq = 1 and coalesce(c.corps2,'') = '' then 'termine'
      when new.etape_seq = 2 and coalesce(c.corps3,'') = '' then 'termine'
      else 'en_cours' end,
    sortie = case when s.statut = 'en_cours' and (new.etape_seq = 3
               or (new.etape_seq = 1 and coalesce(c.corps2,'') = '')
               or (new.etape_seq = 2 and coalesce(c.corps3,'') = '')) then 'fin' else s.sortie end,
    maj_le = now()
  where s.id = new.sequence_id;
  return new;
end $$;
drop trigger if exists ls_sequences_suivi on public.ls_envois;
create trigger ls_sequences_suivi after update of statut on public.ls_envois
  for each row execute function public.ls_sequences_avance();

-- La campagne est terminée quand plus aucune séquence ne court et
-- que la file est vide pour elle.
create or replace function public.ls_campagne_verifier_fin(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.ls_campagnes c set statut = 'terminee', maj_le = now()
   where c.id = p_id and c.statut in ('programmee','en_cours')
     and not exists (select 1 from public.ls_envois e where e.campagne_id = c.id and e.statut in ('en_attente','en_cours'))
     and not exists (select 1 from public.ls_sequences s where s.campagne_id = c.id and s.statut = 'en_cours');
end $$;

create or replace function public.ls_campagnes_maj_statut()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.campagne_id is not null and new.statut in ('envoye','echec','annule') then
    update public.ls_campagnes c set statut = 'en_cours', maj_le = now()
     where c.id = new.campagne_id and c.statut = 'programmee' and new.statut = 'envoye';
    perform public.ls_campagne_verifier_fin(new.campagne_id);
  end if;
  return new;
end $$;

create or replace function public.ls_sequences_fin_campagne()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.statut <> 'en_cours' then perform public.ls_campagne_verifier_fin(new.campagne_id); end if;
  return new;
end $$;
drop trigger if exists ls_sequences_fin on public.ls_sequences;
create trigger ls_sequences_fin after update of statut on public.ls_sequences
  for each row execute function public.ls_sequences_fin_campagne();

-- ── 10. Sortir un contact d'une séquence ───────────────────────────
-- p_sortie : mail (il a répondu), appel (il nous a appelé), stop (il
-- se désabonne), plainte, rebond. Répondu ou appelé : la fiche reçoit
-- l'étiquette de la campagne et revient en tête de file d'appel.
-- Stop ou plainte : l'adresse entre en opposition, pour toujours.
create or replace function public.ls_sequence_sortie(p_id uuid, p_sortie text)
returns void language plpgsql security definer set search_path = public as $$
declare s record; c record; st text;
begin
  if not public.ls_est_staff() and auth.role() <> 'service_role' then
    raise exception 'réservé à l''équipe';
  end if;
  select * into s from public.ls_sequences where id = p_id;
  if s.id is null then return; end if;
  select nom into c from public.ls_campagnes where id = s.campagne_id;
  st := case when p_sortie in ('mail','appel') then 'repondu'
             when p_sortie in ('stop','plainte') then 'desinscrit'
             when p_sortie = 'rebond' then 'rebond'
             else 'arrete' end;
  update public.ls_sequences set statut = st, sortie = p_sortie, sorti_le = now(),
         prochain_le = null, maj_le = now()
   where id = p_id;
  update public.ls_envois set statut = 'annule', erreur = 'sorti de la séquence : ' || p_sortie
   where sequence_id = p_id and statut = 'en_attente';
  if st = 'repondu' then
    update public.ls_prescripteurs set campagne_etiquette = coalesce(c.nom,''), campagne_repondu_id = s.campagne_id,
           rappel_le = coalesce(least(rappel_le, now()), now()), appel_resultat = null
     where id = s.partenaire_id;
    update public.ls_prospects set campagne_etiquette = coalesce(c.nom,''), campagne_repondu_id = s.campagne_id,
           rappel_le = coalesce(least(rappel_le, now()), now()),
           prochaine = 'A répondu à la campagne ' || coalesce(c.nom,'')
     where id = s.prospect_id;
  elsif st = 'desinscrit' then
    insert into public.ls_desinscrits (adresse, canal, motif)
      values (lower(btrim(s.email)), 'email', 'campagne : ' || p_sortie)
      on conflict do nothing;
  elsif st = 'rebond' then
    update public.ls_prescripteurs set email_invalide = true where id = s.partenaire_id;
    update public.ls_prospects set email_invalide = true where id = s.prospect_id;
  end if;
end $$;
grant execute on function public.ls_sequence_sortie(uuid, text) to authenticated, service_role;

-- Un retour reçu de Brevo, rangé et répercuté. Appelée par la fonction
-- « retours » avec la clé service ; jamais depuis la page.
create or replace function public.ls_retour_enregistrer(
  p_evenement text, p_email text, p_message_id text, p_envoi_id uuid, p_motif text, p_brut jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare e record; s record;
begin
  if p_envoi_id is not null then
    select id, boite_id, campagne_id, sequence_id into e from public.ls_envois where id = p_envoi_id;
  elsif coalesce(p_message_id,'') <> '' then
    select id, boite_id, campagne_id, sequence_id into e from public.ls_envois where message_id = p_message_id limit 1;
  end if;
  insert into public.ls_retours (evenement, email, message_id, envoi_id, boite_id, campagne_id, motif, brut)
    values (p_evenement, lower(btrim(coalesce(p_email,''))), coalesce(p_message_id,''), e.id, e.boite_id, e.campagne_id, coalesce(p_motif,''), p_brut);
  if e.id is null then return; end if;
  if p_evenement = 'livre' then
    update public.ls_envois set livre_le = coalesce(livre_le, now()) where id = e.id;
  elsif p_evenement in ('rebond_dur','rebond_doux','bloque') then
    update public.ls_envois set rebond_le = coalesce(rebond_le, now()), rebond_type = p_evenement where id = e.id;
    if e.sequence_id is not null and p_evenement in ('rebond_dur','bloque') then
      update public.ls_sequences set rebonds = rebonds + 1, maj_le = now() where id = e.sequence_id
        returning * into s;
      if s.rebonds >= 2 and s.statut = 'en_cours' then perform public.ls_sequence_sortie(s.id, 'rebond'); end if;
    end if;
  elsif p_evenement = 'plainte' then
    update public.ls_envois set plainte_le = coalesce(plainte_le, now()) where id = e.id;
    if e.sequence_id is not null then perform public.ls_sequence_sortie(e.sequence_id, 'plainte'); end if;
  elsif p_evenement = 'desabonne' then
    if e.sequence_id is not null then perform public.ls_sequence_sortie(e.sequence_id, 'stop'); end if;
  end if;
end $$;
revoke all on function public.ls_retour_enregistrer(text, text, text, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.ls_retour_enregistrer(text, text, text, uuid, text, jsonb) to service_role;

-- Arrêter : ce qui n'est pas parti ne part pas, les séquences s'arrêtent.
create or replace function public.ls_campagne_annuler(p_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.ls_est_staff() then raise exception 'réservé à l''équipe'; end if;
  update public.ls_envois set statut = 'annule'
   where campagne_id = p_id and statut in ('en_attente');
  get diagnostics n = row_count;
  update public.ls_sequences set statut = 'arrete', sortie = 'arret', sorti_le = now(), prochain_le = null, maj_le = now()
   where campagne_id = p_id and statut = 'en_cours';
  update public.ls_campagnes set statut = 'annulee', maj_le = now() where id = p_id;
  return n;
end $$;
grant execute on function public.ls_campagne_annuler(uuid) to authenticated;

-- Supprimer une campagne : ce qui attend est annulé, les séquences
-- partent avec elle, les mails déjà partis restent dans la file (leur
-- campagne_id se vide). Réservé à l'équipe.
create or replace function public.ls_campagne_supprimer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.ls_est_staff() then raise exception 'réservé à l''équipe'; end if;
  update public.ls_envois set statut = 'annule', erreur = 'campagne supprimée'
   where campagne_id = p_id and statut in ('en_attente','en_cours');
  delete from public.ls_campagnes where id = p_id;
end $$;
grant execute on function public.ls_campagne_supprimer(uuid) to authenticated;

-- ── 11. Les métiers présents en base, avec le nombre de fiches ─────
create or replace function public.ls_cible_types(p_activite text)
returns table (type text, fiches bigint, avec_email bigint)
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(type),''),'(sans métier)') as type,
         count(*) as fiches,
         count(*) filter (where coalesce(email,'') <> '' and not email_invalide) as avec_email
    from public.ls_prescripteurs
   where activite = p_activite and public.ls_est_staff()
   group by 1 order by 3 desc, 1;
$$;
grant execute on function public.ls_cible_types(text) to authenticated;

-- ── 12. Les alertes du jour ────────────────────────────────────────
create or replace function public.ls_alertes_mailing()
returns table (genre text, libelle text, valeur numeric, cible_id uuid)
language sql stable security definer set search_path = public as $$
  select 'boite'::text, b.adresse, b.taux_rebond, b.id
    from public.ls_boites_bilan() b
   where b.envoyes_30j >= 20 and b.taux_rebond > 3
  union all
  select 'plainte'::text, b.adresse, b.taux_plainte, b.id
    from public.ls_boites_bilan() b
   where b.envoyes_30j >= 20 and b.taux_plainte > 0.3
  union all
  select 'campagne'::text, c.nom, x.taux_reponse, c.id
    from public.ls_campagnes c
    cross join lateral public.ls_campagne_bilan(c.id) x
   where c.statut in ('en_cours','terminee') and x.envoyes1 >= 50
     and c.lance_le >= now() - interval '60 days'
     and x.taux_reponse < 2;
$$;
grant execute on function public.ls_alertes_mailing() to authenticated;

-- Une campagne qui a répondu, vue depuis la fiche : la séquence active
-- d'une adresse, pour poser les boutons « il a répondu » sur la fiche.
create or replace function public.ls_sequences_de(p_email text)
returns table (id uuid, campagne_id uuid, campagne text, etape smallint, statut text, mail1_le timestamptz)
language sql stable security definer set search_path = public as $$
  select s.id, s.campagne_id, c.nom, s.etape, s.statut, s.mail1_le
    from public.ls_sequences s join public.ls_campagnes c on c.id = s.campagne_id
   where lower(s.email) = lower(btrim(p_email)) and public.ls_est_staff()
   order by s.cree_le desc limit 5;
$$;
grant execute on function public.ls_sequences_de(text) to authenticated;

select 'v3w posée' as etape,
       (select count(*) from public.ls_boites) as boites,
       (select count(*) from public.ls_sequences) as sequences;
notify pgrst, 'reload schema';


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 50-correctif-campagnes-modeles.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — les quatre campagnes, en pilote automatique
--
-- Deux maisons, deux besoins chacune : recruter des clients, recruter
-- des partenaires. Quatre campagnes, qui arrivent écrites.
--
-- Rien ne se clique. Le moteur, qui tourne déjà toutes les cinq
-- minutes, fait désormais trois choses de plus, tout seul :
--   1. il moissonne le registre, métier par métier, département par
--      département, en reprenant là où il s'était arrêté ;
--   2. il cherche les adresses e-mail des fiches qui n'en ont pas ;
--   3. il fait entrer en campagne les contacts qui passent le filtre.
--
-- Le commercial ne touche qu'une chose : ses départements.
--
-- Rejouable sans risque.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1. Le modèle d'une campagne ────────────────────────────────────
alter table public.ls_campagnes
  add column if not exists modele text not null default '';
create index if not exists ls_campagnes_modele_idx
  on public.ls_campagnes (modele) where modele <> '';

-- ── 2. La moisson : où en est le registre, pour chaque campagne ────
-- Une ligne par métier et par département. Le moteur prend la plus
-- ancienne qui n'est pas finie, en fait une tranche, et repose la
-- ligne. Rien ne se perd si une invocation est coupée en route.
create table if not exists public.ls_moisson (
  id           uuid primary key default gen_random_uuid(),
  campagne_id  uuid not null references public.ls_campagnes(id) on delete cascade,
  activite     text not null,
  naf          text not null,
  metier       text not null default '',
  departement  text not null default '',
  page         integer not null default 1,
  fini         boolean not null default false,
  fiches       integer not null default 0,
  souci        text not null default '',
  tourne_le    timestamptz,
  cree_le      timestamptz not null default now(),
  unique (campagne_id, naf, departement)
);
create index if not exists ls_moisson_tour_idx
  on public.ls_moisson (fini, tourne_le nulls first);

alter table public.ls_moisson enable row level security;
drop policy if exists ls_moisson_equipe on public.ls_moisson;
create policy ls_moisson_equipe on public.ls_moisson
  for all to authenticated
  using (public.ls_est_staff()) with check (public.ls_est_staff());

-- L'avancement d'une campagne, en une ligne : combien de tranches
-- faites sur combien, et combien de fiches ramassées.
create or replace function public.ls_moisson_bilan(p_id uuid)
returns table (tranches bigint, finies bigint, fiches bigint, tourne_le timestamptz)
language sql stable security definer set search_path = public as $$
  select count(*), count(*) filter (where fini), coalesce(sum(fiches), 0), max(tourne_le)
    from public.ls_moisson where campagne_id = p_id;
$$;
grant execute on function public.ls_moisson_bilan(uuid) to authenticated;

-- ── 3. Une source peut livrer dans le fichier de prospection ───────
alter table public.ls_sources
  add column if not exists destination text not null default 'leads';
alter table public.ls_sources drop constraint if exists ls_sources_destination_chk;
alter table public.ls_sources add constraint ls_sources_destination_chk
  check (destination in ('leads','prospection'));

-- ── 4. Pharow, la source ───────────────────────────────────────────
-- Créée sans jeton : c'est le CRM qui en tire un au moment où
-- quelqu'un demande l'adresse, et lui seul la connaît.
insert into public.ls_sources (nom, activite, genre, statut, reception, destination, url, note)
select 'Pharow', 'les_deux', 'plateforme', 'a_brancher', 'webhook', 'prospection',
       'https://pharow.com',
       'Ciblage B2B. Livre dans le fichier de prospection, jamais dans la file d''appels. Le code NAF de chaque fiche la range dans la bonne campagne.'
where not exists (select 1 from public.ls_sources where nom = 'Pharow');

-- ── 5. D'où vient une fiche, et sous quelle étiquette ──────────────
alter table public.ls_prescripteurs add column if not exists source text default '';
alter table public.ls_prescripteurs add column if not exists naf text default '';
create index if not exists ls_prescripteurs_source_idx on public.ls_prescripteurs (source);
create index if not exists ls_prescripteurs_type_idx on public.ls_prescripteurs (activite, type);

notify pgrst, 'reload schema';

-- ── 6. Le moteur travaille plus longtemps qu'avant ─────────────────
-- Il envoie, il verse, puis il moissonne : une invocation peut durer
-- une minute. Rien n'est cassé si pg_cron cesse d'attendre la réponse
-- avant la fin, la moisson reprend d'elle-même au tour suivant. Mais
-- pour que le journal soit propre, mieux vaut lui laisser le temps.
-- Cette requête affiche la commande actuelle du cron : envoyez-la moi
-- si vous voulez que j'allonge le délai proprement.
select jobname, schedule, command from cron.job order by jobname;

select 'campagnes avec modèle' as quoi, count(*)::text as combien
  from public.ls_campagnes where modele <> ''
union all
select 'tranches de moisson', count(*)::text from public.ls_moisson
union all
select 'source Pharow', coalesce(max(case when jeton <> '' then 'branchée' else 'sans jeton' end), 'absente')
  from public.ls_sources where nom = 'Pharow';


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 51-correctif-index-fichier.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — les index du fichier de prospection
--
-- Depuis que la moisson tourne toute seule, ls_prescripteurs grossit
-- de plusieurs milliers de lignes par jour. Les écrans qui triaient
-- cette table par date sans index finissaient par dépasser le temps
-- imparti par Postgres : d'où le « ls_prescripteurs : 500 » sur
-- l'écran Affiliation.
--
-- Un index n'est pas un réglage de confort ici : sans lui, chaque
-- affichage relit et trie la table entière. Rejouable.
-- ═══════════════════════════════════════════════════════════════════

-- ── Le tri par date, avec et sans filtre de maison ─────────────────
create index if not exists ls_prescripteurs_cree_idx
  on public.ls_prescripteurs (cree_le desc);
create index if not exists ls_prescripteurs_act_cree_idx
  on public.ls_prescripteurs (activite, cree_le desc);

-- ── Ce que lisent les campagnes et la file d'appels ────────────────
create index if not exists ls_prescripteurs_act_statut_idx
  on public.ls_prescripteurs (activite, statut);
-- Les fiches qui ont une adresse : c'est la seule population que les
-- campagnes regardent, et elle est bien plus petite que la table.
create index if not exists ls_prescripteurs_email_idx
  on public.ls_prescripteurs (activite, type)
  where email is not null and email <> '';
-- Les fiches qui ont un numéro : la file d'appels.
create index if not exists ls_prescripteurs_tel_idx
  on public.ls_prescripteurs (activite, statut)
  where tel is not null and tel <> '';

-- ── Les séquences, lues à chaque passage du moteur ─────────────────
create index if not exists ls_sequences_cree_idx
  on public.ls_sequences (cree_le desc);
create index if not exists ls_sequences_email_idx
  on public.ls_sequences (email);

-- ── L'engrenage : ce qui reste à chercher ──────────────────────────
-- La date de la dernière recherche d'e-mail, écrite par la fonction
-- prospection. La colonne n'était créée nulle part : sans elle, cet
-- index échouait sur une base neuve.
alter table public.ls_prescripteurs add column if not exists mail_cherche_le timestamptz;
create index if not exists ls_prescripteurs_mail_cherche_idx
  on public.ls_prescripteurs (mail_cherche_le nulls first)
  where email is null or email = '';

analyze public.ls_prescripteurs;
analyze public.ls_sequences;

-- Combien de lignes, et d'où elles viennent. C'est ce chiffre qui
-- explique le reste.
select coalesce(nullif(source, ''), 'sans source') as source,
       count(*) as fiches,
       count(*) filter (where email is not null and email <> '') as avec_email,
       count(*) filter (where tel is not null and tel <> '') as avec_tel
  from public.ls_prescripteurs
 group by 1
 order by 2 desc;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 52-schema-signaux.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — les signaux, et la file des chauds
--
-- Appeler à froid un nom tiré du registre, c'est deux pour cent de
-- décrochés utiles. Appeler quelqu'un qui vient d'ouvrir votre mail
-- trois fois, ou qui a cliqué sur votre lien, c'est un autre métier :
-- il connaît déjà votre nom, et vous avez une raison d'appeler.
--
-- Jusqu'ici on jetait ces événements : la fonction « retours » les
-- ignorait explicitement. On les garde désormais sur la fiche, et
-- c'est ce qui remplit la file des chauds.
-- ═══════════════════════════════════════════════════════════════════

-- ── Ce que la fiche retient ────────────────────────────────────────
alter table public.ls_prescripteurs add column if not exists ouvertures int not null default 0;
alter table public.ls_prescripteurs add column if not exists ouvert_le  timestamptz;
alter table public.ls_prescripteurs add column if not exists clics      int not null default 0;
alter table public.ls_prescripteurs add column if not exists clique_le  timestamptz;

alter table public.ls_envois add column if not exists ouvert_le  timestamptz;
alter table public.ls_envois add column if not exists clique_le  timestamptz;

create index if not exists ls_presc_chauds_idx
  on public.ls_prescripteurs (activite, clique_le desc nulls last, ouvert_le desc nulls last);

-- ── L'enregistrement d'un retour, ouvertures et clics compris ──────
-- Même signature qu'avant : la fonction « retours » n'a rien d'autre
-- à changer que d'arrêter de jeter ces deux événements.
create or replace function public.ls_retour_enregistrer(
  p_evenement text, p_email text, p_message_id text, p_envoi_id uuid, p_motif text, p_brut jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare e record; s record;
begin
  if p_envoi_id is not null then
    select id, boite_id, campagne_id, sequence_id, partenaire_id, prospect_id
      into e from public.ls_envois where id = p_envoi_id;
  elsif coalesce(p_message_id,'') <> '' then
    select id, boite_id, campagne_id, sequence_id, partenaire_id, prospect_id
      into e from public.ls_envois where message_id = p_message_id limit 1;
  end if;

  -- Une ouverture n'est pas un incident : on ne l'écrit pas au journal
  -- des retours, qui sert à juger la délivrabilité. On la pose sur la
  -- fiche, et c'est tout.
  if p_evenement not in ('ouvert','clic') then
    insert into public.ls_retours (evenement, email, message_id, envoi_id, boite_id, campagne_id, motif, brut)
      values (p_evenement, lower(btrim(coalesce(p_email,''))), coalesce(p_message_id,''),
              e.id, e.boite_id, e.campagne_id, coalesce(p_motif,''), p_brut);
  end if;
  if e.id is null then return; end if;

  if p_evenement = 'livre' then
    update public.ls_envois set livre_le = coalesce(livre_le, now()) where id = e.id;

  elsif p_evenement = 'ouvert' then
    update public.ls_envois set ouvert_le = coalesce(ouvert_le, now()) where id = e.id;
    if e.partenaire_id is not null then
      update public.ls_prescripteurs
         set ouvertures = ouvertures + 1, ouvert_le = now()
       where id = e.partenaire_id;
    end if;

  elsif p_evenement = 'clic' then
    update public.ls_envois
       set clique_le = coalesce(clique_le, now()), ouvert_le = coalesce(ouvert_le, now())
     where id = e.id;
    if e.partenaire_id is not null then
      update public.ls_prescripteurs
         set clics = clics + 1, clique_le = now(),
             ouvertures = greatest(ouvertures, 1),
             ouvert_le = coalesce(ouvert_le, now())
       where id = e.partenaire_id;
    end if;

  elsif p_evenement in ('rebond_dur','rebond_doux','bloque') then
    update public.ls_envois set rebond_le = coalesce(rebond_le, now()), rebond_type = p_evenement where id = e.id;
    -- Une adresse qui rebondit durement ne sert plus à rien : la fiche
    -- le dit, et elle sort des campagnes suivantes toute seule.
    if p_evenement in ('rebond_dur','bloque') and e.partenaire_id is not null then
      update public.ls_prescripteurs set email_invalide = true where id = e.partenaire_id;
    end if;
    if e.sequence_id is not null and p_evenement in ('rebond_dur','bloque') then
      update public.ls_sequences set rebonds = rebonds + 1, maj_le = now() where id = e.sequence_id
        returning * into s;
      if s.rebonds >= 2 and s.statut = 'en_cours' then perform public.ls_sequence_sortie(s.id, 'rebond'); end if;
    end if;

  elsif p_evenement = 'plainte' then
    update public.ls_envois set plainte_le = coalesce(plainte_le, now()) where id = e.id;
    if e.partenaire_id is not null then
      update public.ls_prescripteurs set email_invalide = true where id = e.partenaire_id;
    end if;
    if e.sequence_id is not null then perform public.ls_sequence_sortie(e.sequence_id, 'plainte'); end if;

  elsif p_evenement = 'desabonne' then
    if e.sequence_id is not null then perform public.ls_sequence_sortie(e.sequence_id, 'stop'); end if;
  end if;
end $$;
revoke all on function public.ls_retour_enregistrer(text, text, text, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.ls_retour_enregistrer(text, text, text, uuid, text, jsonb) to service_role;

-- ── Contrôle ───────────────────────────────────────────────────────
select count(*) filter (where ouvertures > 0) as fiches_ouvreuses,
       count(*) filter (where clics > 0)      as fiches_cliqueuses,
       count(*)                               as fiches
from public.ls_prescripteurs;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 53-correctif-samedi.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — le samedi matin, campagne par campagne
--
-- Le samedi dépend de la cible, pas d'une règle générale. Un artisan,
-- un conducteur de travaux, un commerçant sont à leur poste le samedi
-- matin. Un cabinet comptable, un syndic, un bureau
-- d'études sont fermés, et le mail dort jusqu'à lundi 9 h dans une
-- pile qu'on vide sans lire.
--
-- La campagne porte donc son propre réglage. Le dimanche, jamais.
-- ═══════════════════════════════════════════════════════════════════

alter table public.ls_campagnes
  add column if not exists samedi boolean not null default false;

-- La campagne clients du sur-mesure vise des PME du bâtiment et de
-- l'artisanat, dont le dirigeant fait souvent ses papiers le samedi
-- matin : elle l'active. Les trois autres restent en semaine.
update public.ls_campagnes
   set samedi = true, maj_le = now()
 where modele = 'bornistes_clients';

-- Contrôle : qui écrit le samedi matin, qui n'écrit qu'en semaine.
select nom, modele, statut, samedi
from public.ls_campagnes
order by samedi desc, nom;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 54-echeance-mois.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — « ce sera pour décembre »
--
-- La réponse la plus utile d'un appel, et celle qu'on perd le plus
-- souvent. Notée comme un mois, elle fait désormais trois choses
-- toute seule :
--   1. elle pose le rappel au premier du mois précédent ;
--   2. elle arrête les relances de devis d'ici là, parce qu'on
--      connaît déjà la réponse et qu'insister ne fait qu'agacer ;
--   3. elle envoie un mail de reprise quand le mois approche.
-- ═══════════════════════════════════════════════════════════════════

alter table public.ls_prospects     add column if not exists echeance_le date;
alter table public.ls_prescripteurs add column if not exists echeance_le date;
create index if not exists ls_prospects_echeance_idx on public.ls_prospects (echeance_le)
  where echeance_le is not null;

-- ── Le mail de reprise, un mois avant ──────────────────────────────
-- Une règle par maison (déclencheur echeance_proche), semée par
-- 56-oniq-amorcage.sql.


-- Contrôle
select nom, activite, declencheur, actif from public.ls_regles
where declencheur in ('devis_sans_reponse','echeance_proche')
order by activite, declencheur, delai_min;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 55-relances-devis-automatiques.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — la relance des devis, automatique et par mail
--
-- Un devis envoyé et jamais relancé, c'est une affaire perdue sans
-- qu'on sache pourquoi. Trois messages, à J+3, J+8 et J+15, partis
-- tout seuls, sans bouton, sans liste à regarder.
--
-- Le moteur passe toutes les cinq minutes, prend les devis au statut
-- « envoyé » ou « relancé », et pose le message à la date voulue. Un
-- devis passé en « accepté » ou « refusé » sort immédiatement : les
-- relances suivantes ne partiront pas.
--
-- Les six règles (trois par maison, déclencheur devis_sans_reponse)
-- sont semées par 56-oniq-amorcage.sql.
--
-- AVANT D'EXÉCUTER : passez vos devis de test en « refusé », sinon
-- ils vont recevoir ces trois mails comme les autres.
--   update ls_devis set statut = 'refuse', decide_le = current_date
--    where societe ilike '%test%';
-- ═══════════════════════════════════════════════════════════════════


-- Contrôle : les six règles, actives.
select nom, activite, declencheur, delai_min/1440 as jours, actif
from public.ls_regles
where declencheur = 'devis_sans_reponse'
order by activite, delai_min;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 56-oniq-amorcage.sql
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- ONIQ PILOTAGE — l'amorçage d'ONIQ
--
-- Le contenu de départ de l'entreprise, en un seul endroit : le
-- catalogue, les accroches et les modèles d'e-mail, les fournisseurs
-- de leads, les métiers visés, la liste de démarrage, les règles
-- d'envoi et les réglages de la maison.
--
-- ONIQ n'a qu'une activité, rangée sous la clé technique « bornistes »
-- (figée dans les contraintes, elle ne se renomme pas). La clé
-- « tiimizy » dort : rien n'y est amorcé.
-- Le modèle : ONIQ facture le logiciel (sur mesure, ou l'adaptation
-- d'un de ses logiciels), puis sa maintenance, chaque mois. BatiManager,
-- OniMetri, OniPilote, OniPromail et OniBoost ne se vendent pas : ils
-- sont gratuits et se montrent en démo pendant les rendez-vous.
--
-- Rejouable sans risque : chaque ligne n'est posée que si elle manque.
-- Rien de ce qui a été modifié depuis l'écran n'est écrasé.
-- ═══════════════════════════════════════════════════════════════════


-- ─── 0. L'étape par défaut d'un projet ─────────────────────────────
-- La page choisit toujours l'étape à la création ; cette valeur ne sert
-- qu'à une ligne créée sans elle. C'est la première étape du sur-mesure.
alter table public.ls_chantiers alter column statut set default 'cadrage';


-- ─── 1. Les réglages de la maison ──────────────────────────────────
-- Une valeur déjà renseignée n'est jamais remplacée ; une valeur vide
-- (posée par un bloc précédent) reçoit celle d'ONIQ.
--   site_url      l'adresse du CRM sur Vercel, à remplir une fois déployé
--   vapid_public  la clé publique de notification, à générer pour ce
--                 projet (même valeur que le secret VAPID_PUBLIC)
insert into public.ls_reglages (cle, valeur) values
  ('expediteur_nom',       'ONIQ'),
  ('sms_expediteur',       'ONIQ'),
  ('repondre_a_bornistes', 'contact@oniq.online'),
  ('repondre_a_tiimizy',   'contact@oniq.online'),
  ('site_url',             ''),
  ('vapid_public',         ''),
  ('contrat_version',      '2026-09'),
  ('contrat_modele', E'CONTRAT D''APPORT D''AFFAIRES\n\n'
   || E'Entre les soussignés :\n'
   || E'· ONIQ SOFTWARE SAS, SIREN 103 508 263, dont le siège est à Marsanne (26), ci-après « la Société »,\n'
   || E'· {NOM_PARTENAIRE}, ci-après « l''Apporteur ».\n\n'
   || E'ARTICLE 1 — OBJET\n'
   || E'L''Apporteur met la Société en relation avec des entreprises susceptibles de lui confier la '
   || E'réalisation d''un logiciel, d''une application, d''un site ou d''une automatisation sur mesure, '
   || E'ou l''adaptation de l''un de ses logiciels, ainsi que la maintenance qui s''y rattache. '
   || E'Il n''est ni mandataire, ni agent '
   || E'commercial, ni salarié de la Société, et n''a aucun pouvoir de l''engager.\n\n'
   || E'ARTICLE 2 — MISSION DE L''APPORTEUR\n'
   || E'L''Apporteur transmet à la Société les coordonnées du client et la nature de son besoin. '
   || E'La Société assure seule le cadrage, la maquette, le chiffrage, la contractualisation, la '
   || E'réalisation, la mise en service et le suivi.\n\n'
   || E'ARTICLE 3 — RÉMUNÉRATION\n'
   || E'{REMUNERATION}\n'
   || E'La commission est due sur les affaires effectivement signées et encaissées. Elle est réglée '
   || E'dans les trente jours suivant l''encaissement par la Société des sommes sur lesquelles elle '
   || E'porte, sur facture de l''Apporteur.\n'
   || E'Aucune commission n''est due sur un contact déjà connu de la Société avant sa transmission.\n\n'
   || E'ARTICLE 4 — DURÉE\n'
   || E'Le présent contrat est conclu pour une durée d''un an, renouvelable par tacite reconduction. '
   || E'Chaque partie peut y mettre fin à tout moment moyennant un préavis d''un mois notifié par écrit. '
   || E'Les affaires en cours au jour de la rupture restent dues.\n\n'
   || E'ARTICLE 5 — DONNÉES PERSONNELLES\n'
   || E'L''Apporteur s''assure d''avoir recueilli l''accord du client avant de transmettre ses '
   || E'coordonnées. Les données transmises ne sont utilisées que pour l''exécution du présent contrat.\n\n'
   || E'ARTICLE 6 — CONFIDENTIALITÉ\n'
   || E'Les tarifs, marges, méthodes et éléments techniques portés à la connaissance de l''Apporteur '
   || E'sont confidentiels.\n\n'
   || E'ARTICLE 7 — LOI APPLICABLE\n'
   || E'Le présent contrat est soumis au droit français. À défaut d''accord amiable, tout différend '
   || E'relève des tribunaux compétents.\n')
on conflict (cle) do update
   set valeur = excluded.valeur, maj_le = now()
 where public.ls_reglages.valeur = '';


-- ─── 2. Le catalogue ───────────────────────────────────────────────
-- Le rôle est ce que cherche le chiffrage ; la référence ne sert qu'à
-- retrouver l'article. Les prix sont des points de départ : ils restent
-- « à confirmer » tant qu'ils n'ont pas été décidés, et la page le
-- signale sur chaque devis qui les emploie. Nos logiciels eux-mêmes ne
-- figurent pas au catalogue : ils sont gratuits. Seule leur adaptation
-- se facture, et son prix se saisit une fois décidé (zéro = à saisir).
insert into public.ls_catalogue (reference, designation, role, unite, pv_ht, tva, a_confirmer, actif) values
 ('SM-SITE',    'Site vitrine premium — conception, développement, référencement, mise en ligne',             'sm_site',            'forfait',  4000, 20, true,  true),
 ('SM-ECOM',    'Site e-commerce — catalogue, paiement, référencement',                                       'sm_ecom',            'forfait',  6000, 20, true,  true),
 ('SM-OUTIL',   'Outil métier ciblé — un processus, de la maquette à la mise en service',                     'sm_outil',           'forfait',  7000, 20, true,  true),
 ('SM-APPLI',   'Application de gestion — plusieurs processus, rôles et tableaux de bord',                    'sm_appli',           'forfait', 16000, 20, true,  true),
 ('SM-ERP',     'ERP métier — première vague (le domaine le plus douloureux)',                                'sm_erp',             'forfait', 22000, 20, true,  true),
 ('SM-MOBILE',  'Application mobile ou portail client, fonctionnement hors connexion',                        'sm_mobile',          'forfait', 12000, 20, true,  true),
 ('SM-MODULE',  'Module ou domaine supplémentaire',                                                           'sm_module',          'u',        2500, 20, true,  true),
 ('SM-IA',      'Brique d''intelligence artificielle métier (lecture de documents, chiffrage, assistant)',     'sm_ia',              'u',        3000, 20, true,  true),
 ('SM-INTERF',  'Interfaçage avec un outil existant (comptabilité, banque, outil métier)',                    'interface',          'u',        1200, 20, true,  true),
 ('SM-REPRISE', 'Reprise et migration des données existantes',                                                'reprise',            'forfait',  1500, 20, true,  true),
 ('SM-FORM',    'Formation des équipes, par demi-journée',                                                    'formation',          'u',         450, 20, true,  true),
 ('SM-AUDIT',   'Audit d''automatisation — un à deux jours sur site, liste chiffrée par gain annuel',          'audit_auto',         'forfait',  1350, 20, false, true),
 ('SM-AUTO',    'Automatisation livrée, à la brique',                                                         'automatisation',     'u',         600, 20, true,  true),
 ('SM-PILOT',   'Maintenance mensuelle — hébergement, corrections, mises à jour, petites évolutions',        'pilotage',           'mois',      290, 20, true,  true),
 ('LG-ADAPT',   'Adaptation d''un logiciel ONIQ à votre entreprise — paramétrage, écrans et règles métier',   'lg_adaptation',      'forfait',     0, 20, false, true)
on conflict (reference) do nothing;

-- Une première version vendait les logiciels en abonnement par
-- utilisateur : si elle a été installée, ces articles s'éteignent.
update public.ls_catalogue set actif = false
 where role in ('lg_batimanager','lg_onimetri','lg_onipilote','lg_onipromail','lg_oniboost','lg_mise_en_service');
update public.ls_catalogue
   set designation = 'Maintenance mensuelle — hébergement, corrections, mises à jour, petites évolutions'
 where reference = 'SM-PILOT' and designation like 'Pilotage mensuel%';


-- ─── 3. Les accroches d'appel ──────────────────────────────────────
-- Une ouverture courte : le reste de l'appel se déroule dans les
-- questions de la qualification. Les lignes vides séparent les temps
-- de parole ; l'écran n'en montre qu'un à la fois.
--   lead        la personne nous a contactés
--   froid       on l'appelle sans qu'elle ait rien demandé
--   partenaire  on lui propose de nous recommander
insert into public.ls_modeles (nom, activite, canal, contexte, objet, corps, pieces)
select v.nom, v.activite, 'appel', v.contexte, '', v.corps, '[]'::jsonb
  from (values
 ('Accroche — lead entrant', 'bornistes', 'lead',
  E'Bonjour, {expediteur}, d''ONIQ. {origine} pour un projet de logiciel sur mesure, merci. Je vous pose quelques questions pour bien comprendre ce que vous voulez faire : cinq minutes, et je vous dis ensuite ce que l''on peut vous montrer en maquette.'),

 ('Appel à froid — PME et outils de gestion', 'bornistes', 'froid',
  E'Bonjour, {expediteur}, d''ONIQ. Nous construisons des logiciels de gestion sur mesure pour les PME de la région. Je vous appelle parce que la plupart des entreprises de votre taille pilotent encore une partie de leur activité sur des tableurs et des outils qui ne se parlent pas. Chez vous, qu''est-ce qui se fait encore à la main et vous prend le plus de temps ?'),

 ('Accroche — recrutement partenaire (sur mesure)', 'bornistes', 'partenaire',
  E'Bonjour, {expediteur}, d''ONIQ. Nous développons des logiciels et des applications sur mesure pour les PME.\n\n'
  'Je vous appelle parce que dans votre métier, vos clients vous parlent sûrement de leurs outils : un logiciel qui ne suit plus, des fichiers Excel partout, des saisies faites deux fois.\n\n'
  'Nous avons mis en place un apport d''affaires simple : vous nous présentez l''entreprise, nous faisons le cadrage, la maquette et le devis, et vous touchez une commission sur ce qui se signe. Vous n''avancez rien et vous ne gérez rien.\n\n'
  'Ça vous arrive souvent, ce genre de discussion avec vos clients ?'),

 ('Accroche — demande sur un logiciel', 'bornistes', 'lead',
  E'Bonjour, {expediteur}, d''ONIQ. {origine} au sujet de nos logiciels, merci. Pour vous montrer celui qui vous servira vraiment, je vous pose quelques questions : combien vous êtes, ce que vous utilisez aujourd''hui, et ce qui coince. Cinq minutes, et on cale un rendez-vous pour que je vous le montre.'),

 ('Appel à froid — entreprise du bâtiment (BatiManager)', 'bornistes', 'froid',
  E'Bonjour, {expediteur}, d''ONIQ. Nous avons construit BatiManager, un logiciel de suivi de chantiers et de marges pour les entreprises du bâtiment, et je fais le tour des entreprises de la région pour le leur montrer. Beaucoup de PME du BTP ne connaissent leur marge réelle qu''une fois le chantier terminé. Chez vous, le suivi des budgets et des situations, il se fait comment aujourd''hui ?'),

 ('Appel à froid — métré et DPGF (OniMetri)', 'bornistes', 'froid',
  E'Bonjour, {expediteur}, d''ONIQ. Nous avons construit OniMetri, un outil qui fait le métré à partir des plans et prépare la DPGF. Sur une consultation, le métré est souvent ce qui prend le plus de temps, et c''est là que les erreurs coûtent le plus cher. Aujourd''hui, vos métrés, vous les faites à la main, sur PDF, ou avec un logiciel ?')
) as v(nom, activite, contexte, corps)
 where not exists (select 1 from public.ls_modeles m
                    where m.nom = v.nom and m.activite = v.activite);


-- ─── 4. Les modèles d'e-mail ───────────────────────────────────────
-- Courts, et une seule demande par message. La signature, les
-- coordonnées et le pied de désabonnement s'ajoutent à l'envoi.
-- Deux noms sont cherchés tels quels par la page : « Le devis,
-- expliqué » et « Je vous ai appelé » ; « Partenariat — après l’appel »
-- part tout seul après un appel partenaire concluant.
-- Aucune pièce jointe d'office : la plaquette se rattache depuis
-- l'écran Modèles une fois déposée.
insert into public.ls_modeles (nom, activite, canal, contexte, objet, corps, pieces)
select v.nom, v.activite, 'email', v.contexte, v.objet, v.corps, '[]'::jsonb
  from (values
 -- ── Communs ──
 ('Je vous ai appelé', 'les_deux', 'tous',
  'J''ai essayé de vous joindre',
  E'Bonjour,\n\n'
  'J''ai essayé de vous joindre aujourd''hui, sans succès.\n\n'
  'Le plus simple reste cinq minutes au téléphone : dites-moi quand vous êtes disponible, ou appelez-moi directement au numéro ci-dessous.\n\n'
  'Bien à vous,'),

 ('Partenariat — après l’appel', 'les_deux', 'partenaire',
  'Notre partenariat — la suite',
  E'Bonjour,\n\n'
  'Merci pour cet échange. Voici comment ça marche : vous nous présentez une entreprise qui a besoin d''un logiciel, d''une application ou de l''un de nos outils, nous faisons le reste, et vous recevez une commission sur ce qui se signe. Vous n''avancez rien.\n\n'
  'Je vous envoie votre accès à l''espace partenaire : vous y suivrez vos affaires et vos commissions en temps réel.\n\n'
  'Bien à vous,'),

 -- ── ONIQ ──
 ('Après la démo — la suite', 'bornistes', 'tous',
  'Suite à notre rendez-vous — {societe}',
  E'Bonjour,\n\n'
  'Merci pour le temps que vous m''avez accordé.\n\n'
  'Comme vous l''avez vu, le logiciel sert de point de départ : il ne vous coûte rien. Ce que je vous prépare maintenant, c''est ce qu''il faut adapter pour {societe} — vos écrans, vos règles, vos documents — avec un prix ferme, puis la maintenance mensuelle.\n\n'
  'Si un point vous revient d''ici là, répondez simplement à ce message.\n\n'
  'Bien à vous,'),

 ('Après l''appel — récapitulatif', 'bornistes', 'tous',
  'Suite à notre échange — {societe}',
  E'Bonjour,\n\n'
  'Merci pour votre temps au téléphone.\n\n'
  'Comme convenu, je reprends ce que vous m''avez décrit et je prépare une maquette : vous verrez les écrans de votre futur outil, avec vos propres cas, avant de décider quoi que ce soit.\n\n'
  'Si un point vous revient d''ici là, répondez simplement à ce message.\n\n'
  'Bien à vous,'),

 ('Le devis, expliqué', 'bornistes', 'tous',
  'Votre devis — {societe}',
  E'Bonjour,\n\n'
  'Comme convenu, votre devis est en pièce jointe. Le prix est ferme : il correspond à la maquette que vous avez vue, et il ne bouge pas en cours de route.\n\n'
  '>> Ce qui est compris\n'
  'La construction, la reprise de vos données, la mise en service et la formation de vos équipes. Le code vous appartient, avec sa documentation.\n\n'
  '>> Et après la mise en service\n'
  'La maintenance, chaque mois : hébergement, corrections, mises à jour et petites évolutions. Son montant mensuel figure sur le devis, à part du prix du logiciel.\n\n'
  '>> La suite\n'
  'Une réunion de lancement, puis une livraison chaque semaine : vous voyez l''outil avancer et vous corrigez au fil de l''eau.\n\n'
  'Je reste disponible pour le parcourir avec vous.\n\n'
  'Cordialement,'),

 ('Relance — devis sans réponse', 'bornistes', 'tous',
  'Votre devis — un point rapide ?',
  E'Bonjour,\n\n'
  'Je reviens vers vous au sujet du devis que je vous ai adressé.\n\n'
  'Un point vous arrête : le périmètre, le budget, le calendrier ? Dites-le-moi franchement. On peut découper le projet et commencer par le module le plus utile. Et si c''est non, je préfère le savoir.\n\n'
  'Bien à vous,'),

 ('Demande de pièces après un lead', 'bornistes', 'tous',
  'Ce qu''il me faut pour préparer votre maquette',
  E'Bonjour,\n\n'
  'Pour préparer une maquette qui ressemble vraiment à votre activité, il me faudrait quelques éléments :\n\n'
  '· une capture ou un export de ce que vous utilisez aujourd''hui : tableur, logiciel, formulaire papier ;\n'
  '· un exemple de document que l''outil devra produire : devis, bon d''intervention, rapport, facture ;\n'
  '· la liste des personnes qui s''en serviront, et ce que chacune doit voir ;\n'
  '· les outils avec lesquels il devra échanger, la comptabilité ou la banque par exemple.\n\n'
  'Répondez simplement à ce message avec ce que vous avez, même partiellement. Ces documents restent confidentiels et ne servent qu''à votre maquette.\n\n'
  'Cordialement,'),

 ('Partenariat — apporteur d''affaires (sur mesure)', 'bornistes', 'partenaire',
  'Notre partenariat — {societe}',
  E'Bonjour,\n\n'
  'Merci pour votre temps au téléphone. Comme convenu, voici comment ça marche :\n\n'
  '· Vous nous transmettez le contact d''une entreprise qui a besoin d''un outil : un appel, un message, un mail, comme vous voulez.\n'
  '· Nous la rappelons, nous faisons le cadrage, la maquette et le devis.\n'
  '· Vous touchez votre commission sur le montant HT signé, une fois l''affaire encaissée.\n'
  '· Le client reste le vôtre : nous vous tenons informé à chaque étape.\n\n'
  'Je vous adresse le contrat séparément. Dès qu''il est signé, vous suivez vos dossiers et vos commissions depuis votre espace partenaire.\n\n'
  'Bien à vous,')
) as v(nom, activite, contexte, objet, corps)
 where not exists (select 1 from public.ls_modeles m
                    where m.nom = v.nom and m.activite = v.activite);


-- ─── 5. Les fournisseurs de leads ──────────────────────────────────
-- Tous à brancher. Le jeton de réception se génère depuis l'écran
-- Leads, et c'est lui qu'on donne au formulaire ou au fournisseur.
insert into public.ls_sources (nom, activite, genre, statut, cout_lead, reception, delai_min, url, note)
select v.nom, v.activite, v.genre, 'a_brancher', 0, v.reception, v.delai_min, v.url, v.note
  from (values
 ('Site oniq.online — Demander ma maquette', 'bornistes', 'entrant', 'webhook', 15, 'https://oniq.online',
  'Le formulaire « Demander ma maquette » du site. À brancher sur la fonction lead avec le jeton de cette fiche : la demande remonte en tête de la session d''appels.'),
 ('Google Ads — logiciel sur mesure', 'bornistes', 'entrant', 'manuel', 15, '',
  'Requêtes « logiciel sur mesure », « logiciel de gestion sur mesure », « création ERP PME » en Drôme, Ardèche et Rhône. Les demandes arrivent par le formulaire du site.'),
 ('Malt', 'bornistes', 'plateforme', 'email', 60, 'https://www.malt.fr/',
  'Missions proposées par des entreprises. Répondre dans l''heure avec une question précise sur leur besoin, pas avec un argumentaire.'),
 ('Codeur.com', 'bornistes', 'plateforme', 'email', 60, 'https://www.codeur.com/',
  'Appels d''offres de projets web et logiciels. Beaucoup de petits budgets : ne répondre qu''aux projets qui dépassent un outil métier ciblé.'),
 ('LinkedIn', 'les_deux', 'sortant', 'manuel', 1440, 'https://www.linkedin.com/',
  'Messages directs aux dirigeants et aux responsables d''exploitation. Un message court qui parle de leur activité.'),
 ('Recommandation client', 'les_deux', 'prescripteur', 'manuel', 60, '',
  'Un client qui présente ONIQ à un confrère. Le lead le plus simple à signer : le rappeler dans la journée.'),
 ('Partenaires prescripteurs', 'les_deux', 'prescripteur', 'manuel', 60, '',
  'Experts-comptables, cabinets de conseil, sociétés de services informatiques. Le lead arrive présenté par quelqu''un que le client écoute.'),
 ('Companeo', 'bornistes', 'plateforme', 'webhook', 5, 'https://fac.companeo.com/w3s_get_rfq.php',
  'Facultatif. Place de marché de demandes de devis entre entreprises. Ne sert que si un compte est ouvert : identifiants dans les secrets COMPANEO_USER / COMPANEO_PASS, et fonction companeo déployée.')
) as v(nom, activite, genre, reception, delai_min, url, note)
 where not exists (select 1 from public.ls_sources s where s.nom = v.nom);


-- ─── 6. Les métiers visés ──────────────────────────────────────────
-- Un code NAF, une raison d'appeler, et la façon dont le métier se dit
-- dans l'annuaire ouvert (étiquettes séparées par des virgules ; nom=…
-- est un motif cherché dans l'enseigne).
insert into public.ls_cibles (activite, nom, naf, pourquoi, osm) values
  -- ── Des PME qui ont besoin d'outils métier ──
  ('bornistes','Maçonnerie et gros œuvre','4399C',
   'Devis, plannings d''équipes et suivi de chantier tiennent souvent dans trois fichiers qui ne se parlent pas.',
   'craft=builder,office=construction_company,nom=maconnerie|maçonnerie|gros.oeuvre|batiment|bâtiment'),
  ('bornistes','Construction de maisons individuelles','4120A',
   'Chaque dossier client suit les mêmes étapes, du contrat à la réception : c''est exactement ce qu''un outil métier automatise.',
   'office=construction_company,nom=constructeur|maisons|construction'),
  ('bornistes','Installation électrique','4321A',
   'Interventions, bons de travaux et facturation se ressaisissent d''un outil à l''autre.',
   'craft=electrician,nom=electricite|électricité|electricien|électricien'),
  ('bornistes','Plomberie, chauffage, climatisation','4322A',
   'Contrats d''entretien, interventions et astreintes : un planning et une application mobile changent la journée des techniciens.',
   'craft=plumber,craft=hvac,nom=plomberie|chauffage|sanitaire|climatisation'),
  ('bornistes','Transport routier de marchandises','4941A',
   'Tournées, lettres de voiture et facturation sont des processus répétitifs qu''un logiciel sur mesure fiabilise.',
   'office=logistics,nom=transports|transport|logistique'),
  ('bornistes','Mécanique industrielle','2562B',
   'Devis, ordres de fabrication et suivi d''atelier tiennent rarement dans un ERP standard.',
   'craft=metal_construction,nom=mecanique|mécanique|usinage|chaudronnerie'),
  ('bornistes','Structures métalliques et métallerie','2511Z',
   'Chaque affaire est différente : chiffrage, fabrication et pose demandent un outil taillé pour elles.',
   'craft=metal_construction,nom=metallerie|métallerie|serrurerie|charpente.metallique'),
  ('bornistes','Négoce de matériaux de construction','4673A',
   'Catalogue, tarifs par client et commandes des artisans : un portail client leur fait gagner du temps à tous les deux.',
   'shop=trade,trade=building_supplies,nom=materiaux|matériaux|negoce|négoce'),
  ('bornistes','Négoce de fournitures industrielles','4669B',
   'Des commerciaux terrain, des devis à la chaîne et des relances à la main : un outil de gestion commerciale sur mesure s''y rentabilise vite.',
   'shop=trade,nom=fournitures|industrie|equipement|équipement'),
  ('bornistes','Nettoyage et propreté','8121Z',
   'Plannings d''agents, sites clients et contrôles qualité se gèrent encore souvent au tableur.',
   'craft=cleaning,nom=proprete|propreté|nettoyage'),
  ('bornistes','Aménagement paysager','8130Z',
   'Chantiers courts et nombreux, équipes mobiles : devis et suivi d''intervention depuis le téléphone.',
   'craft=gardener,nom=paysag|espaces.verts|jardin'),
  -- ── Les prescripteurs ──
  ('bornistes','Experts-comptables','6920Z',
   'Ils voient chaque mois les PME qui perdent du temps sur des saisies en double, et on leur demande quel outil prendre.',
   'office=accountant,office=tax_advisor,nom=comptab|expertise.comptable|expert.comptable'),
  ('bornistes','Conseil aux entreprises','7022Z',
   'Ils redessinent les processus de leurs clients et cherchent qui peut construire l''outil qui va avec.',
   'office=consulting,nom=conseil|consulting|organisation'),
  ('bornistes','Sociétés de services informatiques','6202A',
   'Ils installent et maintiennent le parc de leurs clients, mais ne développent pas de logiciel métier : la demande leur arrive quand même.',
   'office=it,nom=informatique|infogerance|infogérance|reseau|réseau'),
  ('bornistes','Agences de communication','7311Z',
   'Leurs clients leur demandent une application ou un outil interne après le site : ils cherchent un partenaire pour le faire.',
   'office=advertising_agency,nom=communication|agence.web|marketing'),

  -- ── Le bâtiment, à qui l'on montre BatiManager et OniMetri ──
  ('bornistes','Construction de maisons individuelles','4120A',
   'Chantiers en parallèle, situations et avenants : BatiManager montre la marge de chaque chantier pendant qu''il se fait.',
   'office=construction_company,nom=constructeur|maisons|construction'),
  ('bornistes','Construction d''autres bâtiments','4120B',
   'Des budgets par lot et des situations mensuelles : c''est le cœur de BatiManager.',
   'office=construction_company,nom=construction|batiment|bâtiment|btp'),
  ('bornistes','Construction de routes','4211Z',
   'Des marchés publics, des métrés et des DPGF à rendre vite : OniMetri raccourcit la réponse aux appels d''offres.',
   'office=construction_company,nom=travaux.publics|routes|terrassement|voirie'),
  ('bornistes','Réseaux pour fluides','4221Z',
   'Des linéaires à métrer sur plan et des chantiers à suivre en budget : OniMetri et BatiManager.',
   'office=construction_company,nom=reseaux|réseaux|canalisation|assainissement'),
  ('bornistes','Installation électrique','4321A',
   'Des chantiers nombreux et courts dont la marge se perd dans les heures non suivies.',
   'craft=electrician,nom=electricite|électricité|electricien|électricien'),
  ('bornistes','Plomberie et installation sanitaire','4322A',
   'Devis, chantiers et achats de matériel à rapprocher : BatiManager le fait sans ressaisie.',
   'craft=plumber,nom=plomberie|sanitaire|chauffage'),
  ('bornistes','Plâtrerie','4331Z',
   'Des surfaces à métrer sur chaque plan : OniMetri les sort en quelques minutes.',
   'craft=plasterer,nom=platrerie|plâtrerie|plaquiste|isolation'),
  ('bornistes','Menuiserie bois et PVC','4332A',
   'Chiffrage, fabrication et pose à suivre affaire par affaire.',
   'craft=carpenter,craft=window_construction,nom=menuiserie|fenetres|fenêtres'),
  ('bornistes','Revêtement des sols et des murs','4333Z',
   'Des métrés de surfaces à chaque devis : OniMetri évite de les refaire à la main.',
   'craft=tiler,craft=floorer,nom=carrelage|revetement|revêtement|sols'),
  ('bornistes','Peinture et vitrerie','4334Z',
   'Des surfaces à métrer et des chantiers courts dont la marge se joue sur les heures.',
   'craft=painter,craft=glaziery,nom=peinture|vitrerie|decoration|décoration'),
  ('bornistes','Charpente','4391A',
   'Des affaires chiffrées au plan et suivies en atelier puis sur chantier.',
   'craft=carpenter,craft=roofer,nom=charpente|couverture|ossature.bois'),
  ('bornistes','Maçonnerie et gros œuvre','4399C',
   'Le cœur de cible de BatiManager : budgets, situations et marges par chantier.',
   'craft=builder,office=construction_company,nom=maconnerie|maçonnerie|gros.oeuvre'),
  ('bornistes','Économistes de la construction','7112B',
   'Leur métier est le métré et la DPGF : OniMetri les produit à partir des plans.',
   'office=engineer,office=quantity_surveyor,nom=economiste|économiste|metreur|métreur|bureau.d.etudes'),
  -- ── ONIQ Logiciels : les PME commerciales pour OniPilote et OniPromail ──
  ('bornistes','Négoce de fournitures industrielles','4669B',
   'Des commerciaux, des devis et des relances : OniPilote tient le pipeline, OniPromail la prospection.',
   'shop=trade,nom=fournitures|industrie|equipement|équipement'),
  ('bornistes','Négoce de matériaux de construction','4673A',
   'Des comptes artisans à suivre et à relancer : OniPilote remplace le fichier partagé.',
   'shop=trade,trade=building_supplies,nom=materiaux|matériaux|negoce|négoce'),
  ('bornistes','Courtiers en assurance','6622Z',
   'Un portefeuille à développer et des échéances à relancer : OniPilote et OniPromail.',
   'office=insurance,nom=assurance|courtage|courtier'),
  ('bornistes','Cabinets de recrutement','7810Z',
   'La prospection d''entreprises est leur quotidien : OniPromail l''automatise sans perdre le ton.',
   'office=employment_agency,nom=recrutement|interim|intérim|emploi'),
  ('bornistes','Experts-comptables','6920Z',
   'Ils conseillent des entreprises du bâtiment sur leurs marges et leurs outils : de bons prescripteurs de BatiManager.',
   'office=accountant,office=tax_advisor,nom=comptab|expertise.comptable|expert.comptable')
on conflict (activite, naf) do nothing;


-- ─── 7. La liste de démarrage ──────────────────────────────────────
-- Des tâches qui ne se font qu'une fois, dans l'ordre où elles
-- débloquent la suite.
insert into public.ls_taches (titre, detail, activite, nature, charge, priorite, ordre)
select v.titre, v.detail, v.activite, 'one_shot', v.charge, v.priorite, v.ordre
  from (values
 -- ── Mise en route ──
 ('Poser les boîtes d''envoi sur mail.oniq.online',
  'Domaine d''envoi authentifié chez Brevo (SPF, DKIM, DMARC), une boîte par commercial, avec sa vraie date de mise en service. Le plafond monte tout seul : ne pas l''antidater.',
  'les_deux','1 h',1,5),
 ('Renseigner l''adresse du site et la clé de notification',
  'Dans les réglages : site_url avec l''adresse du CRM (crm.oniq.online), vapid_public avec la clé publique générée pour ce projet (la même que le secret VAPID_PUBLIC).',
  'les_deux','20 min',1,6),
 -- ── Acquisition ──
 ('Brancher le formulaire « Demander ma maquette » du site',
  'Relier le formulaire d''oniq.online à la fonction lead avec le jeton de sa fiche fournisseur. Tester avec une vraie demande : elle doit remonter en tête de la session d''appels en moins d''une minute.',
  'bornistes','45 min',1,10),
 ('Préparer la maquette type',
  'Un socle réutilisable : connexion, tableau de bord, liste, fiche, export. Chaque maquette de prospect part de là et se livre en deux à cinq jours au lieu de repartir de zéro.',
  'bornistes','1 journée',1,11),
 ('Écrire la trame du cadrage',
  'Les questions des demi-journées de cadrage, dans l''ordre : processus, rôles, documents produits, outils existants, données à reprendre. Elle suit l''ordre de la qualification.',
  'bornistes','1 h 30',2,12),
 ('Lister 50 PME du BTP en Drôme, Ardèche et métropole de Lyon',
  'Maçonnerie, électricité, plomberie, menuiserie, de 10 à 100 salariés. Dirigeant nommé, numéro vérifié. C''est la première file d''appels.',
  'bornistes','2 h',1,13),
 ('Signer 3 experts-comptables prescripteurs',
  'Chacun suit des dizaines de PME et voit passer leurs problèmes d''outils. Le contrat d''apport d''affaires se signe depuis l''espace partenaire.',
  'bornistes','3 h',1,14),
 ('Monter la campagne Google Ads « logiciel sur mesure »',
  'Trois requêtes, trois départements, un budget plafonné. Les annonces mènent au formulaire de maquette, et chaque demande est suivie jusqu''au devis.',
  'bornistes','1 h 30',2,15),
 ('Créer les profils Malt et Codeur.com',
  'Deux réalisations présentées avec captures et chiffres, les prix de départ et les délais. Ne répondre qu''aux projets qui dépassent un outil métier ciblé.',
  'bornistes','1 h',3,16),
 -- ── Les démos ──
 ('Récupérer les anciennes versions des logiciels',
  'BatiManager, OniMetri, OniPilote, OniPromail et OniBoost : retrouver leur code dans les anciens déploiements Vercel ou l''historique GitHub, pour la refonte au design ONIQ.',
  'bornistes','1 h',1,20),
 ('Déposer les démos refondues dans le dossier demos/',
  'Un fichier par logiciel (batimanager.html, onimetri.html…), avec des données fictives crédibles : trois chantiers, des situations, un pipeline. Une démo sur un compte vide ne convainc personne.',
  'bornistes','30 min',1,21),
 ('Fixer le prix de l''adaptation et de la maintenance dans le Catalogue',
  'L''adaptation d''un logiciel ONIQ est à zéro (« à saisir ») et la maintenance à 290 € par mois à titre provisoire. Une fois décidés, décocher « à confirmer ».',
  'bornistes','1 h',1,22)
) as v(titre, detail, activite, charge, priorite, ordre)
 where not exists (select 1 from public.ls_taches t where t.titre = v.titre);


-- ─── 8. Les règles d'envoi ─────────────────────────────────────────
-- Les déclencheurs sont ceux que connaît le moteur, sans en inventer :
-- lead_recu, appel_interesse, devis_sans_reponse, rappel_demain,
-- commission_validee, renouvellement, echeance_proche.
-- Les relances de devis et les reprises d'échéance sont allumées ; les
-- autres sont éteintes : on lit, on adapte le texte, on allume.
insert into public.ls_regles
  (nom, actif, activite, declencheur, delai_min, canal, heures_ouvrees, objet, corps)
select v.nom, v.actif, v.activite, v.declencheur, v.delai_min, v.canal, v.heures_ouvrees, v.objet, v.corps
  from (values
 -- ── Les règles de base, éteintes ──
 ('Accusé de réception d''un lead', false, 'bornistes', 'lead_recu', 2, 'sms', true, '',
  'Bonjour {dirigeant}, votre demande de maquette est bien arrivée chez ONIQ. {expediteur} vous appelle dans quelques minutes pour en parler.'),

 ('Après un appel intéressé', false, 'les_deux', 'appel_interesse', 30, 'email', true,
  'Suite à notre échange — {societe}',
  E'Bonjour {dirigeant},\n\nMerci pour votre temps au téléphone.\n\nComme convenu, je reviens vers vous avec une proposition adaptée à {societe}.\n\nBien à vous,\n{expediteur}'),

 ('Relance d''un devis sans réponse', false, 'les_deux', 'devis_sans_reponse', 7200, 'email', true,
  'Votre devis — {societe}',
  E'Bonjour {dirigeant},\n\nJe me permets de revenir vers vous au sujet du devis envoyé il y a quelques jours.\n\nAvez-vous besoin d''un complément pour avancer ?\n\nBien à vous,\n{expediteur}'),

 ('Rappel de rendez-vous, la veille', false, 'les_deux', 'rappel_demain', 0, 'sms', true, '',
  'Bonjour {dirigeant}, un petit rappel de notre rendez-vous de demain avec ONIQ. À demain, {expediteur}'),

 ('Commission validée', false, 'les_deux', 'commission_validee', 0, 'email', true,
  'Votre commission a été validée',
  E'Bonjour,\n\nUne commission vient d''être validée sur votre espace partenaire. Vous en retrouvez le détail en vous connectant.\n\nBien à vous,\n{expediteur}'),

 ('Commission validée — notification', false, 'les_deux', 'commission_validee', 0, 'push', false,
  'Commission validée',
  'Votre commission de {montant} vient d''être validée. Touchez pour voir le détail.'),

 ('Renouvellement de la maintenance dans 60 jours', false, 'bornistes', 'renouvellement', 0, 'email', true,
  'Votre logiciel — faisons le point',
  E'Bonjour,\n\nLe contrat de maintenance de votre logiciel arrive à sa date anniversaire dans deux mois. C''est le bon moment pour faire le point : ce qui vous sert, ce qui vous manque, et les évolutions à prévoir pour l''année.\n\nVoulez-vous que nous en parlions un quart d''heure ?\n\nBien à vous,\n{expediteur}'),

 -- ── Reprise d'échéance et relances de devis ──
 ('Échéance · reprise un mois avant (sur mesure)', true, 'bornistes', 'echeance_proche', 0, 'email', true,
  'Votre projet de logiciel, pour {mois}',
  E'Bonjour {dirigeant},\n\n'
  'Vous m''aviez dit que le projet serait pour {mois} chez {societe}. On y arrive, alors je reprends contact comme convenu.\n\n'
  'Un repère pour tenir cette date : entre le cadrage, la maquette et les premières livraisons, il faut compter trois à cinq semaines pour un outil ciblé, davantage pour une application complète.\n\n'
  'Si vous voulez être prêt en {mois}, le bon moment pour caler le cadrage, c''est maintenant. Un mot en réponse ou un appel, et on fixe une date.\n\n'
  'Bien à vous,\n{expediteur}'),

 ('Devis sur mesure · relance 1 (J+3)', true, 'bornistes', 'devis_sans_reponse', 4320, 'email', true,
  'Votre devis — {societe}',
  E'Bonjour {dirigeant},\n\n'
  'Je vous ai envoyé il y a quelques jours le devis pour {societe}, {montant}.\n\n'
  'Vous avez pu le regarder ?\n\n'
  'Si un point mérite d''être expliqué, le périmètre, le planning des livraisons ou la reprise de vos données, dites-le-moi et je vous rappelle. C''est souvent plus rapide de vive voix que par écrit.\n\n'
  'Bien à vous,\n{expediteur}'),

 ('Devis sur mesure · relance 2 (J+8)', true, 'bornistes', 'devis_sans_reponse', 11520, 'email', true,
  'Devis {societe} : une question rapide',
  E'Bonjour {dirigeant},\n\n'
  'Sans nouvelle de votre côté sur le devis, je préfère poser la question franchement plutôt que de vous relancer dans le vide.\n\n'
  'Quand un devis reste sans réponse, c''est presque toujours l''une de ces trois raisons : le montant ne passe pas, le calendrier ne colle pas, ou le sujet n''est plus la priorité du moment.\n\n'
  'Dites-moi laquelle et je m''adapte. Sur le montant, on peut découper le projet et commencer par le module le plus utile ; sur le calendrier, on peut décaler le démarrage.\n\n'
  'Bien à vous,\n{expediteur}'),

 ('Devis sur mesure · relance 3 (J+15)', true, 'bornistes', 'devis_sans_reponse', 21600, 'email', true,
  'Je classe le dossier {societe} ?',
  E'Bonjour {dirigeant},\n\n'
  'Je n''ai pas eu de retour sur le devis, et je ne veux pas vous encombrer.\n\n'
  'Je mets le dossier de côté. Si le sujet revient dans quelques mois, gardez ce message : le chiffrage et la maquette restent valables dans leurs grandes lignes, et on repart de là sans tout refaire.\n\n'
  'Et si le projet attend simplement une validation, un mot suffit, je le remets en haut de la pile.\n\n'
  'Bien à vous,\n{expediteur}')
) as v(nom, actif, activite, declencheur, delai_min, canal, heures_ouvrees, objet, corps)
 where not exists (select 1 from public.ls_regles r where r.nom = v.nom);


-- ─── Contrôle ──────────────────────────────────────────────────────
select 'catalogue' as quoi, count(*) filter (where actif) as actifs,
       count(*) filter (where actif and a_confirmer) as a_confirmer
  from public.ls_catalogue
union all
select 'modèles', count(*), count(*) filter (where canal = 'appel') from public.ls_modeles
union all
select 'fournisseurs de leads', count(*), count(*) filter (where statut = 'a_brancher') from public.ls_sources
union all
select 'métiers visés', count(*), count(*) filter (where activite = 'bornistes') from public.ls_cibles
union all
select 'tâches', count(*), count(*) filter (where not fait) from public.ls_taches
union all
select 'règles', count(*), count(*) filter (where actif) from public.ls_regles;


-- ═══════════════════════════════════════════════════════════════════
-- BLOC : 57-oniq-equipe.sql
-- ═══════════════════════════════════════════════════════════════════
-- Le projet Supabase est partagé avec la plateforme ONIQ : tant que
-- l'équipe du CRM est vide, la première personne connectée en serait la
-- direction. On ferme cette porte tout de suite en posant la direction.
insert into public.ls_equipe (email, nom, role, actif)
values ('rubelectro26@gmail.com', 'Ruben Hammarlebiod', 'direction', true)
on conflict (email) do nothing;
