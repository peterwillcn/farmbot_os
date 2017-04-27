defmodule Farmbot.Configurator.Router do
  @moduledoc """
    Routes incoming connections.
  """
  alias Farmbot.System.FS.ConfigStorage
  alias Farmbot.System.Network, as: NetMan
  require Logger

  # max length of a uploaded file.
  @max_length 111_409_842
  @expected_fw_version Application.get_all_env(:farmbot)[:expected_fw_version]

  use Plug.Router
  plug Plug.Logger
  # this is so we can serve the bundle.js file.
  plug Plug.Static, at: "/", from: :farmbot
  plug Plug.Static, at: "/image", from: "/tmp/images", gzip: false

  plug Plug.Parsers, parsers:
    [:urlencoded, :multipart, :json], json_decoder: Poison, length: @max_length
  plug :match
  plug :dispatch
  plug CORSPlug

  target = Mix.Project.config[:target]

  if Mix.env == :dev, do: use Plug.Debugger, otp_app: :farmbot

  get "/", do: conn |> send_resp(200, make_html())
  get "/setup" do
    conn
    |> put_resp_header("location", "http://192.168.24.1/index.html")
    |> send_resp(302, "OK")
  end

  # Arduino-FW or FBOS Upload form.
  get "/firmware/upload" do
    html = ~s"""
    <html>
    <body>
    <p>
    Upload a FarmbotOS Firmware file (.fw) or a Arduino Firmware file (.hex)
    </p>
    <form action="/api/upload_firmware" method="post" enctype="multipart/form-data" accept="*">
      <input type="file" name="firmware" id="fileupload">
      <input type="submit" value="submit">
    </form>
    </body>
    </html>
    """
    conn |> send_resp(200, html)
  end

  # REST API

  # Ping. You know.
  get "/api/ping" do
    conn |> send_resp(200, "PONG")
  end

  if Mix.env() == :dev do
    # Get the current login token. DEV ONLY
    get "/api/token" do
      {:ok, token} = Farmbot.Auth.get_token()
      conn |> make_json |> send_resp(200, Poison.encode!(token))
    end

    # Disable FW signing.
    get "/api/disable_fw_signing" do
      Logger.info "DISABLING FW SIGNING!!!"
      Application.put_env(:nerves_firmware, :pub_key_path, nil)
      conn |> send_resp(200, "OK")
    end
  end

  ## CONFIG/AUTH

  # Get the json config file
  get "/api/config" do
    # Already in json form.
    {:ok, config} = ConfigStorage.read_config_file
    conn |> send_resp(200, config)
  end

  # Post a new json config file. (from configurator)
  post "/api/config" do
    Logger.info ">> router got config json"
    {:ok, _body, conn} = read_body(conn)
    ConfigStorage.replace_config_file(conn.body_params)
    conn |> send_resp(200, "OK")
  end

  # Interim credentials.
  post "/api/config/creds" do
    Logger.info ">> router got credentials"
    {:ok, _body, conn} = read_body(conn)

    %{"email" => email,"pass" => pass,"server" => server} = conn.body_params
    Farmbot.Auth.interim(email, pass, server)
    conn |> send_resp(200, "OK")
  end

  # Try to log in with interim creds + config.
  post "/api/try_log_in" do
    Logger.info "Trying to log in. "
    spawn fn() ->
      # sleep to allow the request to finish.
      Process.sleep(100)

      # restart network.
      # not going to bother checking if it worked or not, (at least until i
      # reimplement networking) because its so fragile.
      Farmbot.System.Network.restart
    end
    conn |> send_resp(200, "OK")
  end

  ## NETWORK

  # Scan for wireless networks.
  post "/api/network/scan" do
    {:ok, _body, conn} = read_body(conn)
    %{"iface" => iface} = conn.body_params
    scan = NetMan.scan(iface)
    case scan do
      {:error, reason} -> conn |> send_resp(500, "could not scan: #{inspect reason}")
      ssids -> conn |> send_resp(200, Poison.encode!(ssids))
    end
  end

  # Configured network Interfaces.
  get "/api/network/interfaces" do
    blah = Farmbot.System.Network.enumerate
    case Poison.encode(blah) do
      {:ok, interfaces} ->
        conn |> send_resp(200, interfaces)
      {:error, reason} ->
        conn |> send_resp(500, "could not enumerate interfaces: #{inspect reason}")
      error ->
        conn |> send_resp(500, "could not enumerate interfaces: #{inspect error}")
    end
  end

  ## STATE PARTS.

  # Log messages.
  get "/api/logs" do
    logs = GenEvent.call(Logger, Logger.Backends.FarmbotLogger, :messages)
    only_messages = Enum.map(logs, fn(log) ->
      log.message
    end)

    json = Poison.encode!(only_messages)
    conn |> make_json |> send_resp(200, json)
  end

  # Full state tree.
  get "/api/state" do
    Farmbot.BotState.Monitor.get_state
     state = :sys.get_state(Farmbot.Transport)
     json = Poison.encode!(state)
     conn |> make_json |> send_resp(200, json)
  end

  # Factory Reset bot.
  post "/api/factory_reset" do
    Logger.info "goodbye."
    spawn fn() ->
      # sleep to allow the request to finish.
      Process.sleep(100)
      Farmbot.System.factory_reset
    end
    conn |> send_resp(204, "GoodByeWorld!")
  end

  ## FIRMWARE

  # FW upload.
  post "/api/upload_firmware" do
    ml = @max_length
    {:ok, _body, conn} = Plug.Conn.read_body(conn, length: ml)
    %{"firmware" => upload} = conn.body_params
    file = upload.path
    case Path.extname(upload.filename) do
      ".hex" ->
        Logger.info "FLASHING ARDUINO!"
        handle_arduino(file, conn)
      ".fw" ->
        Logger.info "FLASHING OS"
        handle_os(file, conn)
      _ -> conn |> send_resp(400, "COULD NOT HANDLE #{upload.filename}")
    end
  end

  # Flash fw that was bundled with the bot.
  post "/api/flash_firmware" do
    "#{:code.priv_dir(:farmbot)}/firmware.hex" |> handle_arduino(conn)
  end

  get "/api/firmware/expected_version" do
    v = @expected_fw_version
    conn |> send_resp(200, v)
  end

  # anything that doesn't match a rest end point gets the index.
  match _, do: conn |> send_resp(404, "not found")

  ## PRIVATE.

  defp make_json(conn), do: conn |> put_resp_content_type("application/json")

  @spec make_html :: binary
  defp make_html do
    "#{:code.priv_dir(:farmbot)}/static/index.html" |> File.read!
  end

  defp handle_arduino(file, conn) do
    errrm = fn(blerp) ->
      receive do
        :done ->
          blerp |> send_resp(200, "OK")
        {:error, reason} ->
          blerp |> send_resp(400, inspect(reason))
      end
    end

    Logger.info ">> is installing a firmware update. "
      <> " I may act weird for a moment", channels: [:toast]

    pid = Process.whereis(Farmbot.Serial.Handler)

    if pid do
      GenServer.cast(Farmbot.Serial.Handler, {:update_fw, file, self()})
      errrm.(conn)
    else
      Logger.info "doing some magic..."
      herp = Nerves.UART.enumerate()
      |> Map.drop(["ttyS0","ttyAMA0"])
      |> Map.keys
      case herp do
        [tty] ->
          Logger.info "magic complete!"
          Farmbot.Serial.Handler.flash_firmware(tty, file, self())
          errrm.(conn)
        _ ->
          Logger.warn "Please only have one serial device when updating firmware"
          conn |> send_resp(200, "OK")
      end
    end
  end

  if target != "host" do
    defp handle_os(file, conn) do
      Logger.info "Firmware update"
      case Nerves.Firmware.upgrade_and_finalize(file) do
        {:error, reason} -> conn |> send_resp(400, inspect(reason))
        :ok ->
          conn |> send_resp(200, "UPGRADING")
          Process.sleep(2000)
          Nerves.Firmware.reboot
      end
    end
  else
    defp handle_os(_file, conn), do: conn |> send_resp(200, "OK")
  end
end