require 'spec_helper'

describe RSpotify::User do
  describe 'refreshing an expired access token' do
    let(:user_id)      { 'wizzler' }
    let(:api_url)      { 'https://api.spotify.com/v1/me/tracks' }
    let(:refreshed_at) { [] }

    # Spotify's 401 body. The wording changed in July 2026: it used to read
    # "The access token expired" and now reads "Missing/invalid/expired access
    # token". Both must trigger a refresh -- the message is not a stable contract.
    def unauthorized_body(message)
      %({"error":{"status":401,"message":"#{message}"}})
    end

    before do
      RSpotify.instance_variable_set(:@client_id, 'test_client_id')
      RSpotify.instance_variable_set(:@client_secret, 'test_client_secret')
      RSpotify::User.class_variable_set('@@users_credentials', {}) if
        RSpotify::User.class_variable_defined?('@@users_credentials')

      RSpotify::User.new(
        'id' => user_id,
        'credentials' => {
          'token'                   => 'expired-access-token',
          'refresh_token'           => 'valid-refresh-token',
          'access_refresh_callback' => ->(token, lifetime) { refreshed_at << [token, lifetime] }
        }
      )

      stub_request(:post, RSpotify::TOKEN_URI).to_return(
        status:  200,
        body:    '{"access_token":"fresh-access-token","expires_in":3600}',
        headers: { 'Content-Type' => 'application/json' }
      )
    end

    ['The access token expired', 'Missing/invalid/expired access token'].each do |message|
      context "when Spotify replies 401 with #{message.inspect}" do
        it 'refreshes the token and retries the request' do
          stub_request(:get, api_url)
            .with(headers: { 'Authorization' => 'Bearer expired-access-token' })
            .to_return(status: 401, body: unauthorized_body(message))

          retried = stub_request(:get, api_url)
            .with(headers: { 'Authorization' => 'Bearer fresh-access-token' })
            .to_return(status: 200, body: '{"items":[]}')

          RSpotify::User.oauth_get(user_id, api_url)

          expect(a_request(:post, RSpotify::TOKEN_URI)).to have_been_made
          expect(retried).to have_been_requested
          expect(refreshed_at).to eq([['fresh-access-token', 3600]])
        end
      end
    end
    context 'when Spotify rotates the refresh token' do
      before do
        stub_request(:post, RSpotify::TOKEN_URI).to_return(
          status:  200,
          body:    '{"access_token":"fresh-access-token","expires_in":3600,' \
                   '"refresh_token":"rotated-refresh-token"}',
          headers: { 'Content-Type' => 'application/json' }
        )

        stub_request(:get, api_url)
          .with(headers: { 'Authorization' => 'Bearer expired-access-token' })
          .to_return(status: 401, body: unauthorized_body('Missing/invalid/expired access token'))
        stub_request(:get, api_url)
          .with(headers: { 'Authorization' => 'Bearer fresh-access-token' })
          .to_return(status: 200, body: '{"items":[]}')
      end

      it 'stores the rotated token so the next refresh does not replay a spent one' do
        RSpotify::User.oauth_get(user_id, api_url)

        credentials = RSpotify::User.class_variable_get('@@users_credentials')[user_id]
        expect(credentials['refresh_token']).to eq('rotated-refresh-token')
      end

      it 'passes the rotated token to a callback that accepts three arguments' do
        received = []
        RSpotify::User.class_variable_get('@@users_credentials')[user_id]['access_refresh_callback'] =
          ->(token, lifetime, refresh) { received << [token, lifetime, refresh] }

        RSpotify::User.oauth_get(user_id, api_url)

        expect(received).to eq([['fresh-access-token', 3600, 'rotated-refresh-token']])
      end

      it 'still calls a two-argument callback without raising ArgumentError' do
        expect { RSpotify::User.oauth_get(user_id, api_url) }.not_to raise_error
        expect(refreshed_at).to eq([['fresh-access-token', 3600]])
      end
    end

  end
end
