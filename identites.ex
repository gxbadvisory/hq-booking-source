defmodule Tymeslot.HQ.Identites do
  @moduledoc "Identités de réservation HQ, déclarées par l'opérateur et jamais par le visiteur."

  def enabled?, do: System.get_env("HQ_BOOKING_IDENTITIES_FILE") not in [nil, ""]

  def organiser(nil, fallback), do: fallback
  def organiser(type, {name, email, username}) do
    if enabled?() do
      identity = config!() |> Map.fetch!("pages") |> Map.fetch!(String.split(type.slug, "-", parts: 2) |> hd())
      {Map.fetch!(identity, "name"), Map.fetch!(identity, "email"), username}
    else
      {name, email, username}
    end
  rescue
    _ -> raise "Identité de réservation HQ indisponible"
  end

  def email(email, nil), do: email
  def email(email, organizer) do
    if enabled?() do
      sender = {Map.fetch!(organizer, :organizer_name), Map.fetch!(organizer, :organizer_email)}
      email
      |> Swoosh.Email.from(sender)
      |> Swoosh.Email.reply_to(sender)
      |> Swoosh.Email.put_private(:hq_sender, elem(sender, 1))
    else
      email
    end
  end

  def delivery(email, overrides) do
    case Map.get(email.private, :hq_sender) do
      nil -> {:ok, overrides}
      sender ->
        try do
          if elem(email.from, 1) != sender, do: raise("Expéditeur incohérent")
          smtp = config!() |> Map.fetch!("smtp") |> Map.fetch!(sender)
          host = Map.fetch!(smtp, "host")
          port = Map.fetch!(smtp, "port")
          pilot? = System.get_env("HQ_BOOKING_MODE") == "pilot" and host == "mailpit" and port == 1025
          if not pilot? and port not in [465, 587], do: raise("SMTP chiffré requis")
          if not pilot? and (smtp["username"] != sender or smtp["password"] in [nil, ""]),
            do: raise("Accès SMTP de cette identité manquant")
          config = Tymeslot.Mailer.SMTPConfig.build(host: host, port: port,
            username: smtp["username"], password: smtp["password"])
          config = config |> Keyword.put_new(:sockopts, [])
            |> Keyword.put_new(:username, "") |> Keyword.put_new(:password, "")
          {:ok, Keyword.merge(overrides, config)}
        rescue
          # Ne jamais journaliser le JSON ni substituer une autre boîte.
          _ -> {:error, :hq_smtp_identity_unavailable}
        end
    end
  end

  defp config! do
    System.fetch_env!("HQ_BOOKING_IDENTITIES_FILE") |> File.read!() |> Jason.decode!()
  end
end
