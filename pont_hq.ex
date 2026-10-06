# Corps injecté dans le contrôleur de santé existant de la release épinglée.
# Aucune création de module dynamique et aucun accès public sans secret serveur.
  import Ecto.Query
  alias Tymeslot.Repo, as: HQRepo
  alias Tymeslot.MeetingTypes, as: HQPages
  alias Tymeslot.Availability.Schedules, as: HQSchedules
  alias Tymeslot.Availability.WeeklySchedule, as: HQWeek
  alias Tymeslot.Integrations.Calendar.Events, as: HQEvents
  alias Tymeslot.Meetings.MeetingSchema, as: HQMeeting

  def hq(conn, params) do
    config = System.fetch_env!("HQ_BOOKING_BRIDGE_FILE") |> File.read!() |> Jason.decode!()
    token = config["token"]
    supplied = get_req_header(conn, "x-hq-booking-token")
    if is_binary(token) and byte_size(token) >= 32 and length(supplied) == 1 and
        Plug.Crypto.secure_compare(token, hd(supplied)) do
      {code, body} = if conn.method == "GET", do: hq_read(params, config), else: hq_write(params, config)
      conn |> put_resp_header("cache-control", "no-store") |> put_status(code) |> json(body)
    else
      conn |> put_status(403) |> json(%{erreur: "Accès privé requis."})
    end
  rescue
    # Les exceptions de transport/configuration peuvent contenir des credentials.
    exception ->
      Logger.error("HQ booking bridge failure", type: inspect(exception.__struct__), calls: Enum.map(__STACKTRACE__, fn {m, f, a, _} -> {m, f, if(is_integer(a), do: a, else: length(a))} end))
      conn |> put_status(503) |> json(%{erreur: "Le service agenda est indisponible. Actualise avant de réessayer."})
  catch
    {:hq, code, message} -> conn |> put_status(code) |> json(%{erreur: message})
  end

  defp hq_fail(code, message), do: throw({:hq, code, message})
  defp hq_hash(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
  defp hq_ok({:ok, value}), do: value
  defp hq_ok(:ok), do: :ok
  defp hq_ok({:error, reason}) when reason in [:precondition_failed, :conditional_not_supported], do: hq_fail(409, "Le calendrier a changé pendant l’enregistrement. Actualise.")
  defp hq_ok({:error, %Ecto.Changeset{} = changeset}), do: hq_fail(422, "Champs invalides : " <> Enum.map_join(changeset.errors, ", ", fn {key, _} -> to_string(key) end))
  defp hq_ok(_), do: hq_fail(422, "Modification refusée. Vérifie les champs et les conflits d’agenda.")
  defp hq_key(slug), do: String.split(slug || "", "-", parts: 2) |> hd()
  defp hq_profile(c), do: Tymeslot.Profiles.get_profile(c["user_id"]) || hq_fail(503, "Profil agenda absent.")
  defp hq_calendar(c, key) do
    item = c["calendars"][key] || hq_fail(422, "Activité inconnue.")
    case Tymeslot.Integrations.CalendarManagement.fetch_integration_for_user(item["integration_id"], c["user_id"]) do
      {:ok, i} when i.is_active ->
        if item["path"] not in i.calendar_paths, do: hq_fail(503, "Calendrier non connecté.")
        {i.id, item["path"]}
      _ -> hq_fail(503, "Calendrier indisponible.")
    end
  end
  defp hq_identity(key) do
    config = System.fetch_env!("HQ_BOOKING_IDENTITIES_FILE") |> File.read!() |> Jason.decode!()
    identity = config["pages"][key] || hq_fail(503, "Identité absente.")
    smtp = config["smtp"][identity["email"]]
    ready = is_map(smtp) and ((System.get_env("HQ_BOOKING_MODE") == "pilot" and smtp["host"] == "mailpit") or
      (smtp["port"] in [465, 587] and smtp["username"] == identity["email"] and is_binary(smtp["password"]) and smtp["password"] != ""))
    Map.merge(identity, %{"smtp_ready" => ready}) |> Map.take(["name", "email", "smtp_ready"])
  end
  defp hq_config(c) do
    p = hq_profile(c)
    pages = HQPages.get_all_meeting_types(c["user_id"]) |> Enum.map(fn t ->
      t |> Map.take([:id, :name, :description, :slug, :duration_minutes, :is_active, :allow_video, :availability_schedule_id])
        |> Map.put(:project, hq_key(t.slug))
    end)
    schedules = HQSchedules.list_for_profile(p.id) |> Enum.map(fn s ->
      days = HQWeek.get_weekly_schedule(s.id) |> Enum.map(fn d ->
        %{day: d.day_of_week, enabled: d.is_available, start: d.start_time, end: d.end_time,
          breaks: Enum.map(d.breaks, &Map.take(&1, [:start_time, :end_time, :label]))}
      end)
      s |> Map.take([:id, :name, :is_default, :buffer_minutes, :min_advance_hours, :advance_booking_days]) |> Map.put(:days, days)
    end)
    calendars = Enum.map(["ne", "di", "gxb", "rappel"], fn key ->
      hq_calendar(c, key)
      Map.merge(hq_identity(key), %{"project" => key})
    end)
    state = %{profile: Map.take(p, [:full_name, :timezone, :username]), pages: pages, schedules: schedules,
      calendars: calendars, public_origin: c["public_origin"], pilot: System.get_env("HQ_BOOKING_MODE") == "pilot"}
    Map.put(state, :revision, hq_hash(state))
  end
  defp hq_read(%{"view" => "events"} = p, c), do: {200, hq_events(p, c)}
  defp hq_read(_, c), do: {200, hq_config(c)}

  defp hq_range(p, timezone) do
    with {:ok, start} <- Date.from_iso8601(p["from"] || ""), {:ok, finish} <- Date.from_iso8601(p["to"] || ""),
         days when days > 0 and days <= 62 <- Date.diff(finish, start) do
      {DateTime.new!(start, ~T[00:00:00], timezone) |> DateTime.shift_zone!("Etc/UTC"), DateTime.new!(finish, ~T[00:00:00], timezone) |> DateTime.shift_zone!("Etc/UTC")}
    else
      _ -> hq_fail(422, "Période invalide (62 jours maximum).")
    end
  end
  defp hq_fresh(c, start, finish) do
    task = Task.Supervisor.async_nolink(Tymeslot.TaskSupervisor, fn ->
      Enum.flat_map(c["calendars"], fn {key, _} ->
        {integration, path} = hq_calendar(c, key)
        context = %HQMeeting{organizer_user_id: c["user_id"], calendar_integration_id: integration, calendar_path: path}
        client = Tymeslot.Integrations.Calendar.Runtime.ClientManager.resolve_client(context)
        case Tymeslot.Integrations.Calendar.EventsRead.fetch_events_with_fallback(client, start, finish) do
          {:ok, events, _} -> Enum.map(events, &Map.merge(&1, %{calendar_integration_id: integration, provider_calendar_id: path}))
          _ -> raise "Calendar unavailable"
        end
      end)
    end)
    case Task.yield(task, 8_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, events} when is_list(events) -> events
      _ -> hq_fail(503, "Les calendriers n’ont pas pu être relus. Leur disponibilité est inconnue.")
    end
  end
  defp hq_event_project(e, c) do
    Enum.find_value(c["calendars"], fn {key, value} ->
      if e.calendar_integration_id == value["integration_id"] and e.provider_calendar_id == value["path"], do: key
    end)
  end
  defp hq_event(e, c) do
    key = hq_event_project(e, c)
    %{uid: e.uid, project: key, title: e[:summary] || "Sans titre", start: e.start_time,
      end: e.end_time, all_day: e[:all_day] == true, location: e[:location], description: e[:description],
      editable: is_binary(key) and String.starts_with?(e.uid, "hq-#{key}-") and (e[:rrule] || e[:recurrence_rule]) in [nil, ""],
      revision: hq_hash(Map.take(e, [:uid, :etag, :summary, :description, :start_time, :end_time, :rrule, :recurrence_rule, :location])), kind: "event"}
  end
  defp hq_meeting(m, c) do
    key = Enum.find_value(c["calendars"], fn {k, v} -> if m.calendar_integration_id == v["integration_id"] and m.calendar_path == v["path"], do: k end)
    %{uid: m.uid, project: key, title: m.title || m.summary || "Rendez-vous", start: m.start_time, end: m.end_time,
      all_day: false, attendee: m.attendee_name, email: m.attendee_email, status: m.status,
      video: m.organizer_video_url || m.meeting_url, revision: hq_hash({m.uid, m.start_time, m.end_time, m.status}), kind: "booking"}
  end
  defp hq_events(p, c) do
    {start, finish} = hq_range(p, hq_profile(c).timezone)
    external = hq_fresh(c, start, finish)
    user = c["user_id"]
    meetings = HQRepo.all(from m in HQMeeting, where: m.organizer_user_id == ^user and m.start_time < ^finish and m.end_time > ^start and m.status != "cancelled")
    ids = MapSet.new(meetings, & &1.uid)
    events = Enum.reject(external, &MapSet.member?(ids, &1.uid)) |> Enum.map(&hq_event(&1, c))
    %{events: Enum.sort_by(events ++ Enum.map(meetings, &hq_meeting(&1, c)), &to_string(&1.start)), read_at: DateTime.utc_now()}
  end

  # Un reçu durable est réservé AVANT tout effet externe. En cas de mort du worker,
  # une reprise n'exécute pas une deuxième fois l'action : relecture explicite requise.
  defp hq_write(p, c) do
    id = p["request_id"]
    unless is_binary(id) and Regex.match?(~r/^[a-f0-9-]{36}$/, id) and byte_size(Jason.encode!(p)) < 20_000,
      do: hq_fail(422, "Identifiant de modification invalide.")
    hash = hq_hash(p)
    inserted = SQL.query!(HQRepo, "INSERT INTO hq_booking_requests(id, fingerprint) VALUES ($1,$2) ON CONFLICT DO NOTHING RETURNING id", [id, hash]).num_rows
    if inserted == 0 do
      [[saved_hash, result]] = SQL.query!(HQRepo, "SELECT fingerprint, result FROM hq_booking_requests WHERE id=$1", [id]).rows
      cond do
        saved_hash != hash -> hq_fail(409, "Identifiant déjà utilisé pour une autre modification.")
        is_nil(result) -> hq_fail(409, "Résultat encore inconnu. Relis l’agenda avant toute nouvelle modification.")
        true -> {result["code"], result["body"]}
      end
    else
      try do
        HQRepo.transaction(fn ->
          SQL.query!(HQRepo, "SELECT pg_advisory_xact_lock(180917, $1)", [c["user_id"]])
          hq_mutate(p, c)
          SQL.query!(HQRepo, "UPDATE hq_booking_requests SET result=$2 WHERE id=$1", [id, %{code: 200, body: %{ok: true}}])
          {200, %{ok: true}}
        end, timeout: 30_000) |> hq_ok()
      catch
        {:hq, code, message} ->
          # Le rollback métier est terminé ; le refus est persisté hors transaction.
          SQL.query!(HQRepo, "UPDATE hq_booking_requests SET result=$2 WHERE id=$1", [id, %{code: code, body: %{erreur: message}}])
          {code, %{erreur: message}}
      end
    end
  end
  defp hq_mutate(%{"action" => action} = p, c) when action in ["page_save", "schedule_save"] do
    if p["revision"] != hq_config(c).revision, do: hq_fail(409, "Les réglages ont changé. Actualise avant d’enregistrer.")
    if action == "page_save", do: hq_save_page(p, c), else: hq_save_schedule(p, c)
  end
  defp hq_mutate(%{"action" => action} = p, c) when action in ["event_save", "event_delete"] do
    key = p["project"]
    {integration, path} = hq_calendar(c, key)
    uid = p["uid"] || "hq-#{key}-#{p["request_id"]}"
    unless Regex.match?(~r/^hq-(ne|di|gxb|rappel)-[a-f0-9-]{36}$/, uid) and String.starts_with?(uid, "hq-#{key}-"), do: hq_fail(422, "Événement non modifiable ici.")
    {start_range, end_range} = hq_range(p, hq_profile(c).timezone)
    events = hq_fresh(c, start_range, end_range)
    old = Enum.find(events, &(&1.uid == uid and hq_event_project(&1, c) == key))
    if p["uid"] && (is_nil(old) or hq_event(old, c).revision != p["event_revision"]), do: hq_fail(409, "L’événement a changé. Actualise l’agenda.")
    context = %HQMeeting{organizer_user_id: c["user_id"], calendar_integration_id: integration, calendar_path: path}
    client = Tymeslot.Integrations.Calendar.Runtime.ClientManager.resolve_client(context)
    if action == "event_delete" do
      if is_nil(old), do: hq_fail(409, "Événement absent. Actualise.")
      Tymeslot.Integrations.Calendar.CalDAV.Events.delete_calendar_event(client.client, path, uid,
        if_match: hq_etag(old), timeout: 8_000) |> hq_ok()
    else
      {start, finish} = hq_times(p, hq_profile(c).timezone)
      title = String.trim(p["title"] || "")
      if String.length(title) not in 1..160 or DateTime.diff(finish, start) not in 60..2_678_400, do: hq_fail(422, "Titre ou durée invalide.")
      event = %{uid: uid, summary: title, start_time: start, end_time: finish, description: "Indisponibilité gérée depuis HQ", location: "", timezone: hq_profile(c).timezone}
      if old do
        Tymeslot.Integrations.Calendar.CalDAV.Events.update_calendar_event(client.client, path, uid, event,
          etag: hq_etag(old), conflict_resolution: :fail, timeout: 8_000) |> hq_ok()
      else
        HQEvents.create_event(event, context) |> hq_ok()
      end
    end
    Tymeslot.Infrastructure.AvailabilityCache.invalidate_for_user(c["user_id"])
  end
  defp hq_mutate(%{"action" => action} = p, c) when action in ["booking_cancel", "booking_move"] do
    m = HQRepo.get_by(HQMeeting, uid: p["uid"], organizer_user_id: c["user_id"]) || hq_fail(404, "Rendez-vous absent.")
    serialized = hq_meeting(m, c)
    if serialized.revision != p["event_revision"], do: hq_fail(409, "Le rendez-vous a changé. Actualise.")
    if not hq_identity(serialized.project)["smtp_ready"], do: hq_fail(422, "Connecte d’abord la boîte email de cette activité pour notifier le participant.")
    if action == "booking_cancel" do
      Tymeslot.Bookings.Cancel.execute(m) |> hq_ok()
    else
      # Refuser les heures ambiguës ou inexistantes avant le parsing du moteur.
      hq_local_time(p["start"], hq_profile(c).timezone)
      [date, time] = String.split(p["start"], "T")
      Tymeslot.Bookings.Reschedule.execute(m.uid, %{date: date, time: time, user_timezone: hq_profile(c).timezone}, %{}, c["user_id"]) |> hq_ok()
    end
  end
  defp hq_mutate(_, _), do: hq_fail(422, "Action inconnue.")

  defp hq_save_page(p, c) do
    old = if p["id"], do: HQPages.get_meeting_type(p["id"], c["user_id"]) || hq_fail(404, "Page absente.")
    key = if old, do: hq_key(old.slug), else: p["project"]
    {integration, path} = hq_calendar(c, key)
    schedule = HQSchedules.get_for_profile(p["schedule_id"], hq_profile(c).id) || hq_fail(422, "Disponibilités inconnues.")
    active = p["active"] == true
    if active and (c["public_origin"] in [nil, ""] or not hq_identity(key)["smtp_ready"]), do: hq_fail(422, "L’ouverture attend le domaine public et la connexion email de cette activité.")
    video = HQRepo.one(from v in Tymeslot.Integrations.Video.VideoIntegrationSchema, where: v.user_id == ^c["user_id"] and v.is_active, order_by: v.id, limit: 1)
    attrs = %{name: p["name"], description: p["description"], duration_minutes: p["duration"], is_active: active,
      is_private: true, user_id: c["user_id"], availability_schedule_id: schedule.id,
      calendar_integration_id: integration, target_calendar_id: path,
      allow_video: p["video"] == true, video_integration_id: if(p["video"] == true and video, do: video.id)}
    if attrs.allow_video and is_nil(video), do: hq_fail(422, "Visio non configurée.")
    if old, do: HQPages.update_meeting_type(old, attrs) |> hq_ok(),
      else: HQPages.create_meeting_type(Map.put(attrs, :slug, key <> "-" <> String.slice(p["request_id"], 0, 8))) |> hq_ok()
  end
  defp hq_save_schedule(p, c) do
    profile = hq_profile(c)
    days = p["days"]
    unless is_list(days) and length(days) == 7 and Enum.sort(Enum.map(days, & &1["day"])) == Enum.to_list(1..7), do: hq_fail(422, "Les sept jours sont requis.")
    s = if p["id"], do: HQSchedules.get_for_profile(p["id"], profile.id) || hq_fail(404, "Disponibilités absentes."), else: HQSchedules.create(profile.id, %{name: p["name"]}) |> hq_ok()
    HQSchedules.rename(s, p["name"]) |> hq_ok()
    HQSchedules.update_policy(s, %{buffer_minutes: p["buffer"], min_advance_hours: p["notice"], advance_booking_days: p["horizon"]}) |> hq_ok()
    Enum.each(days, fn d ->
      attrs = %{is_available: d["enabled"] == true, start_time: d["start"], end_time: d["end"]}
      row = HQWeek.upsert_day_availability(s.id, d["day"], attrs) |> hq_ok()
      # Les pauses préexistantes sont conservées ; le formulaire ne prétend pas les modifier.
      if row.is_available do
        Enum.each(HQWeek.get_day_availability(s.id, d["day"]).breaks, fn b ->
          if Time.compare(b.start_time, row.start_time) == :lt or Time.compare(b.end_time, row.end_time) == :gt,
            do: hq_fail(422, "Une pause existante dépasse les nouveaux horaires.")
        end)
      end
    end)
    Tymeslot.Infrastructure.AvailabilityCache.invalidate_for_user(c["user_id"])
  end
  defp hq_etag(event) do
    value = event[:etag]
    unless is_binary(value) and value != "", do: hq_fail(503, "Révision du calendrier indisponible.")
    "\"" <> String.trim(value, "\"") <> "\""
  end
  defp hq_times(p, timezone), do: {hq_local_time(p["start"], timezone), hq_local_time(p["end"], timezone)}
  defp hq_local_time(value, timezone) do
    with true <- is_binary(value), {:ok, local} <- NaiveDateTime.from_iso8601(value <> ":00"),
         {:ok, datetime} <- DateTime.from_naive(local, timezone) do
      DateTime.shift_zone!(datetime, "Etc/UTC")
    else
      _ -> hq_fail(422, "Heure invalide ou ambiguë lors du changement d’heure. Choisis une autre heure.")
    end
  end
