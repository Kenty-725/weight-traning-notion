require 'json'
require 'net/http'
require 'uri'
require 'logger'
require 'aws-sdk-ssm'

def get_parameter(name, logger)
  ssm = Aws::SSM::Client.new(region: 'ap-northeast-1')
  response = ssm.get_parameter(name: name, with_decryption: true)
  value = response.parameter.value
  logger.debug("#{name} value encoding: #{value.encoding}")
  logger.debug("#{name} value preview: #{value[0..20].inspect}")
  value
end

def lambda_handler(event:, context:)
  logger = Logger.new(STDOUT)
  logger.level = Logger::DEBUG
  logger.debug("Lambda started.")

  begin
    logger.debug("event['body'] encoding: #{event['body']&.encoding}")
    logger.debug("event['body'] preview: #{event['body']&.byteslice(0, 40).inspect}")
    body = JSON.parse(event['body'])
    logger.debug("Parsed body: #{body.inspect}")

    user_message = body.dig("events", 0, "message", "text") || "No message"
    logger.debug("user_message raw: #{user_message.inspect}, encoding: #{user_message.encoding}")

    # ここで明示的にUTF-8変換（エラーが出てもログ）
    begin
      user_message = user_message.to_s.encode("UTF-8")
      logger.debug("user_message after encode: #{user_message.inspect}, encoding: #{user_message.encoding}")
    rescue => e
      logger.error("user_message encode error: #{e.message}")
    end

    notion_api_key = get_parameter('/NOTION_API_KEY', logger)
    notion_database_id = get_parameter('/NOTION_DATABASE_ID', logger)

    logger.debug("Notion API Key: #{notion_api_key.nil? ? 'nil' : 'obtained'}")
    logger.debug("Notion Database ID: #{notion_database_id.nil? ? 'nil' : notion_database_id}")

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

    uri = URI.parse("https://api.notion.com/v1/pages")

    # 💡 Title(プロパティ名) 問題の検証ログ
    title_property = "Title"  # ←あなたのDBのプロパティ名に直してください
    logger.debug("Using Notion property: '#{title_property}'")

    payload = {
      parent: { database_id: notion_database_id },
      properties: {
        title_property => {
          title: [ { text: { content: user_message } } ]
        }
      }
    }

    logger.debug("Payload for Notion: #{payload.inspect}")

    headers = {
      "Authorization" => "Bearer #{notion_api_key}",
      "Content-Type" => "application/json; charset=utf-8",
      "Notion-Version" => "2022-06-28"
    }

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.path, headers)
    
    begin
      request.body = payload.to_json(:ascii_only => false)
      logger.debug("Request body encoding: #{request.body.encoding}")
    rescue => e
      logger.error("payload.to_json error: #{e.message}")
      raise
    end

    logger.info("==== Sending request to Notion")
    begin
      response = http.request(request)
      logger.info("==== Notion response status: #{response.code}")

      # --- ここからが修正point！ ---
      # 外部から来たresponse.bodyをUTF-8エンコードして安全に
      safe_resp_preview = response.body && response.body.byteslice(0,200)
      begin
        safe_resp_preview = safe_resp_preview.to_s.encode('UTF-8', invalid: :replace, undef: :replace)
      rescue => e
        safe_resp_preview = safe_resp_preview.to_s.inspect
      end
      logger.debug("==== Notion response body (first 200 bytes): #{safe_resp_preview}")
      # --- ここまで修正point ---

    rescue => e
      logger.error("HTTP request error: #{e.message}")
      raise
    end

    if response.is_a?(Net::HTTPSuccess)
      # response.bodyをログに出す時もエンコード
      safe_body = response.body.to_s.encode('UTF-8', invalid: :replace, undef: :replace)
      logger.info("Successfully sent to Notion: #{safe_body}")
      {
        statusCode: 200,
        body: JSON.generate({
          message: "✅ Sent to Notion",
          notion_response: safe_body[0..200]
        })
      }
    else
      safe_body = response.body.to_s.encode('UTF-8', invalid: :replace, undef: :replace)
      logger.error("Failed to send to Notion: #{safe_body}")
      {
        statusCode: response.code.to_i,
        body: JSON.generate({
          message: "❌ Failed to send to Notion",
          notion_response: safe_body
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
    logger.error("Unexpected error: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
    {
      statusCode: 500,
      body: JSON.generate({
        message: "Internal Server Error",
        error: "#{e.class} - #{e.message}"
      })
    }
  end
end
