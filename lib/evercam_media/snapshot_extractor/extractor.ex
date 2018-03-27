defmodule EvercamMedia.SnapshotExtractor.Extractor do
  @moduledoc """
  Provides functions to extract images from NVR recordings
  """

  use GenStage
  require Logger
  import EvercamMedia.SnapshotExtractor.ExtractorSchedule, only: [scheduled_now?: 3]

  @root_dir Application.get_env(:evercam_media, :storage_dir)

  ######################
  ## Server Callbacks ##
  ######################

  @doc """
  Initialize the snapmail server
  """
  def init(args) do
    {:producer, args}
  end

  @doc """
  """
  def handle_cast({:snapshot_extractor, config}, state) do
    _start_extractor(state, config)
    {:noreply, [], state}
  end

  #####################
  # Private functions #
  #####################

  defp _start_extractor(_state, config) do
    spawn fn ->
      start_date = config.start_date
      end_date = config.end_date
      url = nvr_url(config.host, config.port, config.username, config.password, config.channel)
      images_directory = "#{@root_dir}/#{config.exid}/extract/#{config.id}/"
      upload_path =
        case config.requester do
          "marklensmen@gmail.com" ->
            "/Construction/#{config.exid}/#{config.id}/"
          _ ->
            "/Construction2/#{config.exid}/#{config.id}/"
        end
      File.mkdir_p(images_directory)
      kill_ffmpeg_pids(config.host, config.port, config.username, config.password)
      {:ok, _, _, status} = Calendar.DateTime.diff(start_date, end_date)
      iterate(status, config, url, start_date, end_date, images_directory, upload_path, 1)
    end
  end

  defp iterate(:before, config, url, start_date, end_date, path, upload_path, index) do
    case scheduled_now?(config.schedule, start_date, "UTC") do
      {:ok, true} ->
        Logger.debug "Extracting snapshot from NVR."
        extract_image(url, start_date, path, upload_path, index)
      {:ok, false} ->
        Logger.debug "Not Scheduled. Skip extracting snapshot from NVR."
      {:error, _message} ->
        Logger.error "Error getting scheduler snapshot from NVR."
    end
    next_start_date = start_date |> Calendar.DateTime.advance!(config.interval)
    {:ok, _, _, status} = Calendar.DateTime.diff(next_start_date, end_date)
    iterate(status, config, url, next_start_date, end_date, path, upload_path, index + 1)
  end
  defp iterate(_status, config, _url, start_date, end_date, path, upload_path, _index) do
    :timer.sleep(:timer.seconds(5))
    create_video_mp4(config.mp4, config, path, upload_path)
    update_snapshot_extractor(config, path)
    Logger.debug "Start date (#{start_date}) greater than end date (#{end_date})."
  end

  def create_video_mp4("true", config, path, upload_path) do
    Porcelain.shell("ffmpeg -r 6 -i #{path}%d.jpg -c:v h264_nvenc -r 6 -preset slow -bufsize 1000k -pix_fmt yuv420p -y #{path}#{config.exid}.mp4", [err: :out]).out
    spawn(fn ->
      File.exists?("#{path}#{config.exid}.mp4")
      |> upload_image("#{path}#{config.exid}.mp4", "#{upload_path}#{config.exid}.mp4")
      clean_images(path)
    end)
  end
  def create_video_mp4(_, _config, _path, _upload_path), do: :nothing

  defp update_snapshot_extractor(config, path) do
    snapshot_extractor = SnapshotExtractor.by_id(config.id)
    snapshot_count = get_count(path)
    EvercamMedia.UserMailer.snapshot_extraction_completed(snapshot_extractor, snapshot_count)
    params = %{status: 12, notes: "Extracted images = #{snapshot_count}"}
    SnapshotExtractor.update_snapshot_extactor(snapshot_extractor, params)
  end

  defp get_count(images_path) do
    case File.exists?(images_path) do
      true ->
        Enum.count(File.ls!(images_path))
      _ ->
        0
    end
  end

  defp extract_image(url, start_date, path, upload_path, index) do
    image_name = start_date |> Calendar.Strftime.strftime!("%Y-%m-%d-%H-%M-%S")
    images_path = "#{path}#{index}.jpg"
    upload_image_path = "#{upload_path}#{image_name}.jpg"
    save_current_jpeg_time(image_name, path)
    startdate_iso = convert_to_iso(start_date)
    enddate_iso = start_date |> Calendar.DateTime.advance!(10) |> convert_to_iso
    stream_url = "#{url}?starttime=#{startdate_iso}&endtime=#{enddate_iso}"
    Porcelain.shell("ffmpeg -rtsp_transport tcp -stimeout 100000000 -i '#{stream_url}' -vframes 1 -y #{images_path}").out
    spawn(fn ->
      File.exists?(images_path)
      |> upload_image(images_path, upload_image_path)
    end)
  end

  defp upload_image(true, image_path, upload_image_path) do
    client = ElixirDropbox.Client.new(System.get_env["DROP_BOX_TOKEN"])
    case ElixirDropbox.Files.upload(client, upload_image_path, image_path) do
      {{:status_code, _}, {:error, error}} -> Logger.debug "Error while uploading. Error: #{inspect error}"
      _ -> :noop
    end
  end
  defp upload_image(_status, _image_path, _upload_image_path), do: :noop

  defp nvr_url(ip, port, username, password, channel) do
    "rtsp://#{username}:#{password}@#{ip}:#{port}/Streaming/tracks/#{channel}"
  end

  defp save_current_jpeg_time(name, path) do
    File.write!("#{path}CURRENT", name)
  end

  defp convert_to_iso(datetime) do
    datetime
    |> Calendar.Strftime.strftime!("%Y%m%dT%H%M%SZ")
  end

  defp kill_ffmpeg_pids(ip, port, username, password) do
    rtsp_url = "rtsp://#{username}:#{password}@#{ip}:#{port}/Streaming/tracks/"
    Porcelain.shell("ps -ef | grep ffmpeg | grep '#{rtsp_url}' | grep -v grep | awk '{print $2}'").out
    |> String.split
    |> Enum.each(fn(pid) -> Porcelain.shell("kill -9 #{pid}") end)
  end

  defp clean_images(images_directory) do
    File.rm_rf!(images_directory)
  end
end
