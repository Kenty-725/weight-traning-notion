require 'json'
require 'net/http'
require 'uri'
require 'logger'
require 'aws-sdk-ssm'

def get_parameter(name)
  ssm = Aws::SSM::Client.new(region: 'ap-northeast-1')
  response = ssm.get_parameter(name: name, with_decryption: true)
  response.parameter.value
end

# N行目をパースするメソッド
def parse_training_line(line)
  # 例: "ベンチプレス 50Kg 10回"（全角スペースも対応）
  if line =~ /^(.+?)[\s　]+(\d+)[kK][gG][\s　]+(\d+)回$/
    menu = $1.strip
    weight = $2.to_i
    reps = $3.to_i
    [menu, weight, reps]
  else
    [nil, nil, nil]
  end
end

def lambda_handler(event:, context:)
  logger = Logger.new(STDOUT)
  logger.level = Logger::DEBUG

  begin
    body = JSON.parse(event['body'])
    user_message = body.dig("events", 0, "message", "text") || "No message"

    logger.debug("Received user message: #{user_message}")

    notion_api_key = get_parameter('/NOTION_API_KEY')
    notion_database_id = get_parameter('/NOTION_DATABASE_ID')

    if notion_api_key.nil? || notion_database_id.nil?
      logger.warn("Missing environment variables for Notion API.")
      return {
        statusCode: 200,
        body: JSON.generate({
          message: "🧪 Test mode: Notion API not called (missing env vars)",
          user_message: user_message
        })
      }
    end

    # === ここから改修 ===
    lines = user_message.strip.split(/[\r\n]+/)
    training_type = lines[0]&.strip || ""

    # 2〜5行目をパース（最大4種目分）
    menus_weights_reps = (1..4).map { |i| parse_training_line(lines[i] || "") }
    # menus_weights_reps => [[menu1, weight1, reps1], [menu2, weight2, reps2], ...]

    today_str = Time.now.strftime('%Y-%m-%d') # ISO8601形式(YYYY-MM-DD)

    # Notion API リクエストの準備
    properties = {
      "TrainingType" => {
        "title" => [
          { "text" => { "content" => training_type } }
        ]
      },
      "WorkoutDate" => {
        "date" => { "start" => today_str }
      }
    }

    menus_weights_reps.each_with_index do |(menu, weight, reps), idx|
      n = idx + 1
      properties["TrainingMenu#{n}"] = {
        "rich_text" => [
          { "text" => { "content" => menu.to_s } }
        ]
      }
      properties["Weight#{n}"] = {
        "number" => weight.nil? || weight == 0 ? nil : weight
      }
      properties["Reps#{n}"] = {
        "number" => reps.nil? || reps == 0 ? nil : reps
      }
    end

    payload = {
      parent: { database_id: notion_database_id },
      properties: properties
    }
    # === ここまで改修 ===

    uri = URI.parse("https://api.notion.com/v1/pages")
    headers = {
      "Authorization" => "Bearer #{notion_api_key}",
      "Content-Type" => "application/json",
      "Notion-Version" => "2022-06-28"
    }

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.path, headers)
    request.body = payload.to_json

    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      safe_body = response.body.to_s.encode('UTF-8', invalid: :replace, undef: :replace)
      logger.info("Successfully sent to Notion: #{safe_body}")
      {
        statusCode: 200,
        body: JSON.generate({
          message: "✅ Sent to Notion",
          notion_response: response.body[0..200]
        })
      }
    else
      logger.error("Failed to send to Notion: #{response.body}")
      {
        statusCode: response.code.to_i,
        body: JSON.generate({
          message: "❌ Failed to send to Notion",
          notion_response: response.body
        })
      }
    end

  rescue Aws::SSM::Errors::ServiceError => e
    logger.error("SSMエラー: #{e.message}")
    {
      statusCode: 500,
      body: JSON.generate({
        message: "SSM parameter retrieval error: #{e.message}"
      })
    }
  rescue JSON::ParserError => e
    logger.error("JSON parse error: #{e.message}")
    {
      statusCode: 400,
      body: JSON.generate({
        message: "Invalid JSON format."
      })
    }
  rescue StandardError => e
    logger.error("Unexpected error: #{e.message}")
    {
      statusCode: 500,
      body: JSON.generate({
        message: "Internal Server Error",
        error: e.message
      })
    }
  end
end
