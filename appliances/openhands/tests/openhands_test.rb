require_relative '../../../lib/community/app_handler'

RSpec.describe 'OpenHands Appliance' do
  before(:all) do
    @app = Community::AppHandler.new
    @app.wait_until_ready(timeout: 600)
  end

  it 'has docker running' do
    expect(@app.execute('systemctl is-active docker').strip).to eq('active')
  end

  it 'has the openhands container running' do
    result = @app.execute('docker inspect -f "{{.State.Running}}" openhands').strip
    expect(result).to eq('true')
  end

  it 'serves HTTPS on port 443' do
    result = @app.execute('curl -sk -o /dev/null -w "%{http_code}" https://localhost/')
    expect(result.strip).to eq('401')
  end

  it 'returns 200 with valid auth' do
    password = @app.execute('cat /var/lib/openhands/password').strip
    result = @app.execute(
      "curl -sk -u admin:#{password} -o /dev/null -w \"%{http_code}\" https://localhost/"
    )
    expect(result.strip).to eq('200')
  end

  it 'has the conversations API reachable' do
    password = @app.execute('cat /var/lib/openhands/password').strip
    result = @app.execute(
      "curl -sk -u admin:#{password} https://localhost/api/conversations"
    )
    parsed = JSON.parse(result)
    expect(parsed).to be_a(Array)
  end

  it 'has the workspace directory' do
    result = @app.execute('test -d /opt/openhands/workspace && echo ok').strip
    expect(result).to eq('ok')
  end

  it 'has the report file with connection info' do
    result = @app.execute('cat /etc/one-appliance/config')
    expect(result).to include('endpoint')
    expect(result).to include('password')
  end
end
