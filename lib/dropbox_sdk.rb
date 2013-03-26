require 'rubygems'
require 'uri'
require 'net/https'
require 'cgi'
require 'json'
require 'yaml'

module Dropbox # :nodoc:
    API_SERVER = "api.dropbox.com"
    API_CONTENT_SERVER = "api-content.dropbox.com"
    WEB_SERVER = "www.dropbox.com"
    
    API_VERSION = 1
    SDK_VERSION = "1.5.1"

    TRUSTED_CERT_FILE = File.join(File.dirname(__FILE__), 'trusted-certs.crt')
end

# DropboxSession is responsible for holding OAuth information.  It knows how to take your consumer key and secret
# and request an access token, an authorize url, and get an access token.  You just need to pass it to
# DropboxClient after its been authorized.
class DropboxSession

    # * consumer_key - Your Dropbox application's "app key".
    # * consumer_secret - Your Dropbox application's "app secret".
    def initialize(consumer_key, consumer_secret)
        @consumer_key = consumer_key
        @consumer_secret = consumer_secret
        @request_token = nil
        @access_token = nil
    end

    private

    def do_http(uri, auth_token, request) # :nodoc:
        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = true
        enable_cert_checking(http)
        http.ca_file = Dropbox::TRUSTED_CERT_FILE

        request.add_field('Authorization', build_auth_header(auth_token))

        #We use this to better understand how developers are using our SDKs.
        request['User-Agent'] =  "OfficialDropboxRubySDK/#{Dropbox::SDK_VERSION}"

        begin
            http.request(request)
        rescue OpenSSL::SSL::SSLError => e
            raise DropboxError.new("SSL error connecting to Dropbox.  " +
                                   "There may be a problem with the set of certificates in \"#{Dropbox::TRUSTED_CERT_FILE}\".  " +
                                   e)
        end
    end

    def enable_cert_checking(http)
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end

    def build_auth_header(token) # :nodoc:
        header = "OAuth oauth_version=\"1.0\", oauth_signature_method=\"PLAINTEXT\", " +
            "oauth_consumer_key=\"#{URI.escape(@consumer_key)}\", "
        if token
            key = URI.escape(token.key)
            secret = URI.escape(token.secret)
            header += "oauth_token=\"#{key}\", oauth_signature=\"#{URI.escape(@consumer_secret)}&#{secret}\""
        else
            header += "oauth_signature=\"#{URI.escape(@consumer_secret)}&\""
        end
        header
    end

    def do_get_with_token(url, token, headers=nil) # :nodoc:
        uri = URI.parse(url)
        do_http(uri, token, Net::HTTP::Get.new(uri.request_uri))
    end

    public

    def do_get(url, headers=nil)  # :nodoc:
        assert_authorized
        do_get_with_token(url, @access_token)
    end

    def do_http_with_body(uri, request, body)
        if body != nil
            if body.is_a?(Hash)
                form_data = {}
                body.each {|k,v| form_data[k.to_s] = v if !v.nil?}
                request.set_form_data(form_data)
            elsif body.respond_to?(:read)
                if body.respond_to?(:length)
                    request["Content-Length"] = body.length.to_s
                elsif body.respond_to?(:stat) && body.stat.respond_to?(:size)
                    request["Content-Length"] = body.stat.size.to_s
                else
                    raise ArgumentError, "Don't know how to handle 'body' (responds to 'read' but not to 'length' or 'stat.size')."
                end
                request.body_stream = body
            else
                s = body.to_s
                request["Content-Length"] = s.length
                request.body = s
            end
        end
        do_http(uri, @access_token, request)
    end

    def do_post(url, headers=nil, body=nil)  # :nodoc:
        assert_authorized
        uri = URI.parse(url)
        do_http_with_body(uri, Net::HTTP::Post.new(uri.request_uri, headers), body)
    end

    def do_put(url, headers=nil, body=nil)  # :nodoc:
        assert_authorized
        uri = URI.parse(url)
        do_http_with_body(uri, Net::HTTP::Put.new(uri.request_uri, headers), body)
    end


    def get_token(url_end, input_token, error_message_prefix) #: nodoc:
        response = do_get_with_token("https://#{Dropbox::API_SERVER}:443/#{Dropbox::API_VERSION}/oauth#{url_end}", input_token)
        if not response.kind_of?(Net::HTTPSuccess) # it must be a 200
            raise DropboxAuthError.new("#{error_message_prefix}  Server returned #{response.code}: #{response.message}.", response)
        end
        parts = CGI.parse(response.body)

        if !parts.has_key? "oauth_token" and parts["oauth_token"].length != 1
            raise DropboxAuthError.new("Invalid response from #{url_end}: missing \"oauth_token\" parameter: #{response.body}", response)
        end
        if !parts.has_key? "oauth_token_secret" and parts["oauth_token_secret"].length != 1
            raise DropboxAuthError.new("Invalid response from #{url_end}: missing \"oauth_token\" parameter: #{response.body}", response)
        end

        OAuthToken.new(parts["oauth_token"][0], parts["oauth_token_secret"][0])
    end

    # This returns a request token.  Requests one from the dropbox server using the provided application key and secret if nessecary.
    def get_request_token()
        @request_token ||= get_token("/request_token", nil, "Error getting request token.  Is your app key and secret correctly set?")
    end

    # This returns a URL that your user must visit to grant
    # permissions to this application.
    def get_authorize_url(callback=nil)
        get_request_token()

        url = "/#{Dropbox::API_VERSION}/oauth/authorize?oauth_token=#{URI.escape(@request_token.key)}"
        if callback
            url += "&oauth_callback=#{URI.escape(callback)}"
        end
        if @locale
            url += "&locale=#{URI.escape(@locale)}"
        end

        "https://#{Dropbox::WEB_SERVER}#{url}"
    end

    # Clears the access_token
    def clear_access_token
        @access_token = nil
    end

    # Returns the request token, or nil if one hasn't been acquired yet.
    def request_token
        @request_token
    end

    # Returns the access token, or nil if one hasn't been acquired yet.
    def access_token
        @access_token
    end

    # Given a saved request token and secret, set this location's token and secret
    # * token - this is the request token
    # * secret - this is the request token secret
    def set_request_token(key, secret)
        @request_token = OAuthToken.new(key, secret)
    end

    # Given a saved access token and secret, you set this Session to use that token and secret
    # * token - this is the access token
    # * secret - this is the access token secret
    def set_access_token(key, secret)
        @access_token = OAuthToken.new(key, secret)
    end

    # Returns the access token. If this DropboxSession doesn't yet have an access_token, it requests one
    # using the request_token generate from your app's token and secret.  This request will fail unless
    # your user has gone to the authorize_url and approved your request
    def get_access_token
        return @access_token if authorized?

        if @request_token.nil?
            raise DropboxAuthError.new("No request token. You must set this or get an authorize url first.")
        end

        @access_token = get_token("/access_token", @request_token,  "Couldn't get access token.")
    end

    # If we have an access token, then do nothing.  If not, throw a RuntimeError.
    def assert_authorized
        unless authorized?
            raise RuntimeError.new('Session does not yet have a request token')
        end
    end

    # Returns true if this Session has been authorized and has an access_token.
    def authorized?
        !!@access_token
    end

    # serialize the DropboxSession.
    # At DropboxSession's state is capture in three key/secret pairs.  Consumer, request, and access.
    # Serialize returns these in a YAML string, generated from a converted array of the form:
    # [consumer_key, consumer_secret, request_token.token, request_token.secret, access_token.token, access_token.secret]
    # access_token is only included if it already exists in the DropboxSesssion
    def serialize
        toreturn = []
        if @access_token
            toreturn.push @access_token.secret, @access_token.key
        end

        get_request_token

        toreturn.push @request_token.secret, @request_token.key
        toreturn.push @consumer_secret, @consumer_key

        toreturn.to_yaml
    end

    # Takes a serialized DropboxSession YAML String and returns a new DropboxSession object
    def self.deserialize(ser)
        ser = YAML::load(ser)
        session = DropboxSession.new(ser.pop, ser.pop)
        session.set_request_token(ser.pop, ser.pop)

        if ser.length > 0
            session.set_access_token(ser.pop, ser.pop)
        end
        session
    end
end


# A class that represents either an OAuth request token or an OAuth access token.
class OAuthToken # :nodoc:
    def initialize(key, secret)
        @key = key
        @secret = secret
    end

    def key
        @key
    end

    def secret
        @secret
    end
end


# This is the usual error raised on any Dropbox related Errors
class DropboxError < RuntimeError
    attr_accessor :http_response, :error, :user_error
    def initialize(error, http_response=nil, user_error=nil)
        @error = error
        @http_response = http_response
        @user_error = user_error
    end

    def to_s
        return "#{user_error} (#{error})" if user_error
        "#{error}"
    end
end

# This is the error raised on Authentication failures.  Usually this means
# one of three things
# * Your user failed to go to the authorize url and approve your application
# * You set an invalid or expired token and secret on your Session
# * Your user deauthorized the application after you stored a valid token and secret
class DropboxAuthError < DropboxError
end

# This is raised when you call metadata with a hash and that hash matches
# See documentation in metadata function
class DropboxNotModified < DropboxError
end

# This is the Dropbox Client API you'll be working with most often.  You need to give it
# a DropboxSession which has already been authorized, or which it can authorize.
class DropboxClient

    # Initialize a new DropboxClient.  You need to give it a session which has been authorized. See
    # documentation on DropboxSession for how to authorize it.
    def initialize(session, root="app_folder", locale=nil)
        session.get_access_token

        @root = root.to_s  # If they passed in a symbol, make it a string

        if not ["dropbox","app_folder"].include?(@root)
            raise DropboxError.new("root must be :dropbox or :app_folder")
        end
        if @root == "app_folder"
            #App Folder is the name of the access type, but for historical reasons
            #sandbox is the URL root component that indicates this
            @root = "sandbox"
        end

        @locale = locale
        @session = session
    end

    # Parse response. You probably shouldn't be calling this directly.  This takes responses from the server
    # and parses them.  It also checks for errors and raises exceptions with the appropriate messages.
    def parse_response(response, raw=false) # :nodoc:
        if response.kind_of?(Net::HTTPServerError)
            raise DropboxError.new("Dropbox Server Error: #{response} - #{response.body}", response)
        elsif response.kind_of?(Net::HTTPUnauthorized)
            raise DropboxAuthError.new(response, "User is not authenticated.")
        elsif not response.kind_of?(Net::HTTPSuccess)
            begin
                d = JSON.parse(response.body)
            rescue
                raise DropboxError.new("Dropbox Server Error: body=#{response.body}", response)
            end
            if d['user_error'] and d['error']
                raise DropboxError.new(d['error'], response, d['user_error'])  #user_error is translated
            elsif d['error']
                raise DropboxError.new(d['error'], response)
            else
                raise DropboxError.new(response.body, response)
            end
        end

        return response.body if raw

        begin
            return JSON.parse(response.body)
        rescue JSON::ParserError
            raise DropboxError.new("Unable to parse JSON response: #{response.body}", response)
        end
    end

    # Returns account info in a Hash object
    #
    # For a detailed description of what this call returns, visit:
    # https://www.dropbox.com/developers/reference/api#account-info
    def account_info()
        response = @session.do_get build_url("/account/info")
        parse_response(response)
    end

    # Uploads a file to a server.  This uses the HTTP PUT upload method for simplicity
    #
    # Arguments:
    # * to_path: The directory path to upload the file to. If the destination
    #   directory does not yet exist, it will be created.
    # * file_obj: A file-like object to upload. If you would like, you can
    #   pass a string as file_obj.
    # * overwrite: Whether to overwrite an existing file at the given path. [default is False]
    #   If overwrite is False and a file already exists there, Dropbox
    #   will rename the upload to make sure it doesn't overwrite anything.
    #   You must check the returned metadata to know what this new name is.
    #   This field should only be True if your intent is to potentially
    #   clobber changes to a file that you don't know about.
    # * parent_rev: The rev field from the 'parent' of this upload. [optional]
    #   If your intent is to update the file at the given path, you should
    #   pass the parent_rev parameter set to the rev value from the most recent
    #   metadata you have of the existing file at that path. If the server
    #   has a more recent version of the file at the specified path, it will
    #   automatically rename your uploaded file, spinning off a conflict.
    #   Using this parameter effectively causes the overwrite parameter to be ignored.
    #   The file will always be overwritten if you send the most-recent parent_rev,
    #   and it will never be overwritten you send a less-recent one.
    # Returns:
    # * a Hash containing the metadata of the newly uploaded file.  The file may have a different name if it conflicted.
    #
    # Simple Example
    #  client = DropboxClient(session, :app_folder)
    #  #session is a DropboxSession I've already authorized
    #  client.put_file('/test_file_on_dropbox', open('/tmp/test_file'))
    # This will upload the "/tmp/test_file" from my computer into the root of my App's app folder
    # and call it "test_file_on_dropbox".
    # The file will not overwrite any pre-existing file.
    def put_file(to_path, file_obj, overwrite=false, parent_rev=nil)
        path = "/files_put/#{@root}#{format_path(to_path)}"

        params = {
            'overwrite' => overwrite.to_s
        }

        params['parent_rev'] = parent_rev unless parent_rev.nil?

        response = @session.do_put(build_url(path, params, content_server=true),
                                   {"Content-Type" => "application/octet-stream"},
                                   file_obj)

        parse_response(response)
    end

    # Returns a ChunkedUploader object.
    #
    # Args:
    # * file_obj: The file-like object to be uploaded.  Must support .read()
    # * total_size: The total size of file_obj
    def get_chunked_uploader(file_obj, total_size)
        ChunkedUploader.new(self, file_obj, total_size)
    end

    # ChunkedUploader is responsible for uploading a large file to Dropbox in smaller chunks.
    # This allows large files to be uploaded and makes allows recovery during failure.
    class ChunkedUploader
        attr_accessor :file_obj, :total_size, :offset, :upload_id, :client

        def initialize(client, file_obj, total_size)
            @client = client
            @file_obj = file_obj
            @total_size = total_size
            @upload_id = nil
            @offset = 0
        end

        # Uploads data from this ChunkedUploader's file_obj in chunks, until
        # an error occurs. Throws an exception when an error occurs, and can
        # be called again to resume the upload.
        #
        # Args:
        # * chunk_size: The chunk size for each individual upload.  Defaults to 4MB.
        def upload(chunk_size=4*1024*1024)
            last_chunk = nil

            while @offset < @total_size
                if not last_chunk
                    last_chunk = @file_obj.read(chunk_size)
                end

                resp = {}
                begin
                    resp = @client.parse_response(@client.partial_chunked_upload(last_chunk, @upload_id, @offset))
                    last_chunk = nil
                rescue DropboxError => e
                    resp = JSON.parse(e.http_response.body)
                    raise unless resp.has_key? 'offset'
                end

                if resp.has_key? 'offset' and resp['offset'] > @offset
                    @offset += (resp['offset'] - @offset) if resp['offset']
                    last_chunk = nil
                end
                @upload_id = resp['upload_id'] if resp['upload_id']
            end
        end

        # Completes a file upload
        #
        # Args:
        # * to_path: The directory path to upload the file to. If the destination
        #   directory does not yet exist, it will be created.
        # * overwrite: Whether to overwrite an existing file at the given path. [default is False]
        #   If overwrite is False and a file already exists there, Dropbox
        #   will rename the upload to make sure it doesn't overwrite anything.
        #   You must check the returned metadata to know what this new name is.
        #   This field should only be True if your intent is to potentially
        #   clobber changes to a file that you don't know about.
        # * parent_rev: The rev field from the 'parent' of this upload.
        #   If your intent is to update the file at the given path, you should
        #   pass the parent_rev parameter set to the rev value from the most recent
        #   metadata you have of the existing file at that path. If the server
        #   has a more recent version of the file at the specified path, it will
        #   automatically rename your uploaded file, spinning off a conflict.
        #   Using this parameter effectively causes the overwrite parameter to be ignored.
        #   The file will always be overwritten if you send the most-recent parent_rev,
        #   and it will never be overwritten you send a less-recent one.
        #
        # Returns:
        # *  A Hash with the metadata of file just uploaded.
        #    For a detailed description of what this call returns, visit:
        #    https://www.dropbox.com/developers/reference/api#metadata
        def finish(to_path, overwrite=false, parent_rev=nil)
            response = @client.commit_chunked_upload(to_path, @upload_id, overwrite, parent_rev)
            @client.parse_response(response)
        end
    end

    def commit_chunked_upload(to_path, upload_id, overwrite=false, parent_rev=nil)  #:nodoc
        params = {'overwrite' => overwrite.to_s,
                  'upload_id' => upload_id,
                  'parent_rev' => parent_rev.to_s,
                }
        @session.do_post(build_url("/commit_chunked_upload/#{@root}#{format_path(to_path)}", params, content_server=true))
    end

    def partial_chunked_upload(data, upload_id=nil, offset=nil)  #:nodoc
        params = {}
        params['upload_id'] = upload_id.to_s if upload_id
        params['offset'] = offset.to_s if offset
        @session.do_put(build_url('/chunked_upload', params, content_server=true),
                                {'Content-Type' => "application/octet-stream"},
                                data)
    end

    # Download a file
    #
    # Args:
    # * from_path: The path to the file to be downloaded
    # * rev: A previous revision value of the file to be downloaded
    #
    # Returns:
    # * The file contents.
    def get_file(from_path, rev=nil)
        response = get_file_impl(from_path, rev)
        parse_response(response, raw=true)
    end

    # Download a file and get its metadata.
    #
    # Args:
    # * from_path: The path to the file to be downloaded
    # * rev: A previous revision value of the file to be downloaded
    #
    # Returns:
    # * The file contents.
    # * The file metadata as a hash.
    def get_file_and_metadata(from_path, rev=nil)
        response = get_file_impl(from_path, rev)
        parsed_response = parse_response(response, raw=true)
        metadata = parse_metadata(response)
        return parsed_response, metadata
    end

    # Download a file (helper method - don't call this directly).
    #
    # Args:
    # * from_path: The path to the file to be downloaded
    # * rev: A previous revision value of the file to be downloaded
    #
    # Returns:
    # * The HTTPResponse for the file download request.
    def get_file_impl(from_path, rev=nil) # :nodoc:
        params = {}
        params['rev'] = rev.to_s if rev

        path = "/files/#{@root}#{format_path(from_path)}"
        @session.do_get build_url(path, params, content_server=true)
    end
    private :get_file_impl

    # Parses out file metadata from a raw dropbox HTTP response.
    #
    # Args:
    # * dropbox_raw_response: The raw, unparsed HTTPResponse from Dropbox.
    #
    # Returns:
    # * The metadata of the file as a hash.
    def parse_metadata(dropbox_raw_response) # :nodoc:
        begin
            raw_metadata = dropbox_raw_response['x-dropbox-metadata']
            metadata = JSON.parse(raw_metadata)
        rescue
            raise DropboxError.new("Dropbox Server Error: x-dropbox-metadata=#{raw_metadata}",
                                   dropbox_raw_response)
        end
        return metadata
    end
    private :parse_metadata

    # Copy a file or folder to a new location.
    #
    # Arguments:
    # * from_path: The path to the file or folder to be copied.
    # * to_path: The destination path of the file or folder to be copied.
    #   This parameter should include the destination filename (e.g.
    #   from_path: '/test.txt', to_path: '/dir/test.txt'). If there's
    #   already a file at the to_path, this copy will be renamed to
    #   be unique.
    #
    # Returns:
    # * A hash with the metadata of the new copy of the file or folder.
    #   For a detailed description of what this call returns, visit:
    #   https://www.dropbox.com/developers/reference/api#fileops-copy
    def file_copy(from_path, to_path)
        params = {
            "root" => @root,
            "from_path" => format_path(from_path, false),
            "to_path" => format_path(to_path, false),
        }
        response = @session.do_post build_url("/fileops/copy", params)
        parse_response(response)
    end

    # Create a folder.
    #
    # Arguments:
    # * path: The path of the new folder.
    #
    # Returns:
    # *  A hash with the metadata of the newly created folder.
    #    For a detailed description of what this call returns, visit:
    #    https://www.dropbox.com/developers/reference/api#fileops-create-folder
    def file_create_folder(path)
        params = {
            "root" => @root,
            "path" => format_path(path, false),
        }
        response = @session.do_post build_url("/fileops/create_folder", params)

        parse_response(response)
    end

    # Deletes a file
    #
    # Arguments:
    # * path: The path of the file to delete
    #
    # Returns:
    # *  A Hash with the metadata of file just deleted.
    #    For a detailed description of what this call returns, visit:
    #    https://www.dropbox.com/developers/reference/api#fileops-delete
    def file_delete(path)
        params = {
            "root" => @root,
            "path" => format_path(path, false),
        }
        response = @session.do_post build_url("/fileops/delete", params)
        parse_response(response)
    end

    # Moves a file
    #
    # Arguments:
    # * from_path: The path of the file to be moved
    # * to_path: The destination path of the file or folder to be moved
    #   If the file or folder already exists, it will be renamed to be unique.
    #
    # Returns:
    # *  A Hash with the metadata of file or folder just moved.
    #    For a detailed description of what this call returns, visit:
    #    https://www.dropbox.com/developers/reference/api#fileops-delete
    def file_move(from_path, to_path)
        params = {
            "root" => @root,
            "from_path" => format_path(from_path, false),
            "to_path" => format_path(to_path, false),
        }
        response = @session.do_post build_url("/fileops/move", params)
        parse_response(response)
    end

    # Retrives metadata for a file or folder
    #
    # Arguments:
    # * path: The path to the file or folder.
    # * list: Whether to list all contained files (only applies when
    #   path refers to a folder).
    # * file_limit: The maximum number of file entries to return within
    #   a folder. If the number of files in the directory exceeds this
    #   limit, an exception is raised. The server will return at max
    #   25,000 files within a folder.
    # * hash: Every directory listing has a hash parameter attached that
    #   can then be passed back into this function later to save on
    #   bandwidth. Rather than returning an unchanged folder's contents, if
    #   the hash matches a DropboxNotModified exception is raised.
    # * rev: Optional. The revision of the file to retrieve the metadata for.
    #   This parameter only applies for files. If omitted, you'll receive
    #   the most recent revision metadata.
    # * include_deleted: Specifies whether to include deleted files in metadata results.
    #
    # Returns:
    # * A Hash object with the metadata of the file or folder (and contained files if
    #   appropriate).  For a detailed description of what this call returns, visit:
    #   https://www.dropbox.com/developers/reference/api#metadata
    def metadata(path, file_limit=25000, list=true, hash=nil, rev=nil, include_deleted=false)
        params = {
            "file_limit" => file_limit.to_s,
            "list" => list.to_s,
            "include_deleted" => include_deleted.to_s
        }

        params["hash"] = hash if hash
        params["rev"] = rev if rev

        response = @session.do_get build_url("/metadata/#{@root}#{format_path(path)}", params=params)
        if response.kind_of? Net::HTTPRedirection
                raise DropboxNotModified.new("metadata not modified")
        end
        parse_response(response)
    end

    # Search directory for filenames matching query
    #
    # Arguments:
    # * path: The directory to search within
    # * query: The query to search on (3 character minimum)
    # * file_limit: The maximum number of file entries to return/
    #   If the number of files exceeds this
    #   limit, an exception is raised. The server will return at max 1,000
    # * include_deleted: Whether to include deleted files in search results
    #
    # Returns:
    # * A Hash object with a list the metadata of the file or folders matching query
    #   inside path.  For a detailed description of what this call returns, visit:
    #   https://www.dropbox.com/developers/reference/api#search
    def search(path, query, file_limit=1000, include_deleted=false)
        params = {
            'query' => query,
            'file_limit' => file_limit.to_s,
            'include_deleted' => include_deleted.to_s
        }

        response = @session.do_get build_url("/search/#{@root}#{format_path(path)}", params)
        parse_response(response)
    end

    # Retrive revisions of a file
    #
    # Arguments:
    # * path: The file to fetch revisions for. Note that revisions
    #   are not available for folders.
    # * rev_limit: The maximum number of file entries to return within
    #   a folder. The server will return at max 1,000 revisions.
    #
    # Returns:
    # * A Hash object with a list of the metadata of the all the revisions of
    #   all matches files (up to rev_limit entries)
    #   For a detailed description of what this call returns, visit:
    #   https://www.dropbox.com/developers/reference/api#revisions
    def revisions(path, rev_limit=1000)

        params = {
            'rev_limit' => rev_limit.to_s
        }

        response = @session.do_get build_url("/revisions/#{@root}#{format_path(path)}", params)
        parse_response(response)

    end

    # Restore a file to a previous revision.
    #
    # Arguments:
    # * path: The file to restore. Note that folders can't be restored.
    # * rev: A previous rev value of the file to be restored to.
    #
    # Returns:
    # * A Hash object with a list the metadata of the file or folders restored
    #   For a detailed description of what this call returns, visit:
    #   https://www.dropbox.com/developers/reference/api#search
    def restore(path, rev)
        params = {
            'rev' => rev.to_s
        }

        response = @session.do_post build_url("/restore/#{@root}#{format_path(path)}", params)
        parse_response(response)
    end

    # Returns a direct link to a media file
    # All of Dropbox's API methods require OAuth, which may cause problems in
    # situations where an application expects to be able to hit a URL multiple times
    # (for example, a media player seeking around a video file). This method
    # creates a time-limited URL that can be accessed without any authentication.
    #
    # Arguments:
    # * path: The file to stream.
    #
    # Returns:
    # * A Hash object that looks like the following:
    #      {'url': 'https://dl.dropbox.com/0/view/wvxv1fw6on24qw7/file.mov', 'expires': 'Thu, 16 Sep 2011 01:01:25 +0000'}
    def media(path)
        response = @session.do_get build_url("/media/#{@root}#{format_path(path)}")
        parse_response(response)
    end

    # Get a URL to share a media file
    # Shareable links created on Dropbox are time-limited, but don't require any
    # authentication, so they can be given out freely. The time limit should allow
    # at least a day of shareability, though users have the ability to disable
    # a link from their account if they like.
    #
    # Arguments:
    # * path: The file to share.
    #
    # Returns:
    # * A Hash object that looks like the following example:
    #      {'url': 'http://www.dropbox.com/s/m/a2mbDa2', 'expires': 'Thu, 16 Sep 2011 01:01:25 +0000'}
    #   For a detailed description of what this call returns, visit:
    #    https://www.dropbox.com/developers/reference/api#shares
    def shares(path)
        response = @session.do_get build_url("/shares/#{@root}#{format_path(path)}")
        parse_response(response)
    end

    # Download a thumbnail for an image.
    #
    # Arguments:
    # * from_path: The path to the file to be thumbnailed.
    # * size: A string describing the desired thumbnail size. At this time,
    #   'small' (32x32), 'medium' (64x64), 'large' (128x128), 's' (64x64),
    #   'm' (128x128), 'l' (640x640), and 'xl' (1024x1024) are officially supported sizes.
    #   Check https://www.dropbox.com/developers/reference/api#thumbnails
    #   for more details. [defaults to large]
    # Returns:
    # * The thumbnail data
    def thumbnail(from_path, size='large')
        response = thumbnail_impl(from_path, size)
        parse_response(response, raw=true)
    end

    # Download a thumbnail for an image along with the image's metadata.
    #
    # Arguments:
    # * from_path: The path to the file to be thumbnailed.
    # * size: A string describing the desired thumbnail size. See thumbnail()
    #   for details.
    # Returns:
    # * The thumbnail data
    # * The metadata for the image as a hash
    def thumbnail_and_metadata(from_path, size='large')
        response = thumbnail_impl(from_path, size)
        parsed_response = parse_response(response, raw=true)
        metadata = parse_metadata(response)
        return parsed_response, metadata
    end

    # A way of letting you keep a local representation of the Dropbox folder
    # heirarchy.  You can periodically call delta() to get a list of "delta
    # entries", which are instructions on how to update your local state to
    # match the server's state.
    #
    # Arguments:
    # * +cursor+: On the first call, omit this argument (or pass in +nil+).  On
    #   subsequent calls, pass in the +cursor+ string returned by the previous
    #   call.
    #
    # Returns: A hash with three fields.
    # * +entries+: A list of "delta entries" (described below)
    # * +reset+: If +true+, you should reset local state to be an empty folder
    #   before processing the list of delta entries.  This is only +true+ only
    #   in rare situations.
    # * +cursor+: A string that is used to keep track of your current state.
    #   On the next call to delta(), pass in this value to return entries
    #   that were recorded since the cursor was returned.
    # * +has_more+: If +true+, then there are more entries available; you can
    #   call delta() again immediately to retrieve those entries.  If +false+,
    #   then wait at least 5 minutes (preferably longer) before checking again.
    #
    # Delta Entries: Each entry is a 2-item list of one of following forms:
    # * [_path_, _metadata_]: Indicates that there is a file/folder at the given
    #   path.  You should add the entry to your local state.  (The _metadata_
    #   value is the same as what would be returned by the #metadata() call.)
    #   * If the path refers to parent folders that don't yet exist in your
    #     local state, create those parent folders in your local state.  You
    #     will eventually get entries for those parent folders.
    #   * If the new entry is a file, replace whatever your local state has at
    #     _path_ with the new entry.
    #   * If the new entry is a folder, check what your local state has at
    #     _path_.  If it's a file, replace it with the new entry.  If it's a
    #     folder, apply the new _metadata_ to the folder, but do not modify
    #     the folder's children.
    # * [path, +nil+]: Indicates that there is no file/folder at the _path_ on
    #   Dropbox.  To update your local state to match, delete whatever is at
    #   _path_, including any children (you will sometimes also get separate
    #   delta entries for each child, but this is not guaranteed).  If your
    #   local state doesn't have anything at _path_, ignore this entry.
    #
    # Remember: Dropbox treats file names in a case-insensitive but case-preserving
    # way.  To facilitate this, the _path_ strings above are lower-cased versions of
    # the actual path.  The _metadata_ dicts have the original, case-preserved path.
    def delta(cursor=nil)
        params = {}
        if cursor
            params['cursor'] = cursor
        end

        response = @session.do_post build_url("/delta", params)
        parse_response(response)
    end

    # Download a thumbnail (helper method - don't call this directly).
    #
    # Args:
    # * from_path: The path to the file to be thumbnailed.
    # * size: A string describing the desired thumbnail size. See thumbnail()
    #   for details.
    #
    # Returns:
    # * The HTTPResponse for the thumbnail request.
    def thumbnail_impl(from_path, size='large') # :nodoc:
        from_path = format_path(from_path, true)

        params = {
            "size" => size
        }

        url = build_url("/thumbnails/#{@root}#{from_path}", params, content_server=true)

        @session.do_get url
    end
    private :thumbnail_impl


    # Creates and returns a copy ref for a specific file.  The copy ref can be
    # used to instantly copy that file to the Dropbox of another account.
    #
    # Args:
    # * path: The path to the file for a copy ref to be created on.
    #
    # Returns:
    # * A Hash object that looks like the following example:
    #      {"expires"=>"Fri, 31 Jan 2042 21:01:05 +0000", "copy_ref"=>"z1X6ATl6aWtzOGq0c3g5Ng"}
    def create_copy_ref(path)
        path = "/copy_ref/#{@root}#{format_path(path)}"

        response = @session.do_get(build_url(path, {}))

        parse_response(response)
    end

    # Adds the file referenced by the copy ref to the specified path
    #
    # Args:
    # * copy_ref: A copy ref string that was returned from a create_copy_ref call.
    #   The copy_ref can be created from any other Dropbox account, or from the same account.
    # * to_path: The path to where the file will be created.
    #
    # Returns:
    # * A hash with the metadata of the new file.
    def add_copy_ref(to_path, copy_ref)
        path = "/fileops/copy"

        params = {'from_copy_ref' => copy_ref,
                  'to_path' => "#{to_path}",
                  'root' => @root}

        response = @session.do_post(build_url(path, params))

        parse_response(response)
    end

    def build_url(url, params=nil, content_server=false) # :nodoc:
        port = 443
        host = content_server ? Dropbox::API_CONTENT_SERVER : Dropbox::API_SERVER
        versioned_url = "/#{Dropbox::API_VERSION}#{url}"

        target = URI::Generic.new("https", nil, host, port, nil, versioned_url, nil, nil, nil)

        #add a locale param if we have one
        #initialize a params object is we don't have one
        if @locale
            (params ||= {})['locale']=@locale
        end

        if params
            target.query = params.collect {|k,v|
                CGI.escape(k) + "=" + CGI.escape(v)
            }.join("&")
        end

        target.to_s
    end

    #From the oauth spec plus "/".  Slash should not be ecsaped
    RESERVED_CHARACTERS = /[^a-zA-Z0-9\-\.\_\~\/]/

    def format_path(path, escape=true) # :nodoc:
        path = path.gsub(/\/+/,"/")
        # replace multiple slashes with a single one

        path = path.gsub(/^\/?/,"/")
        # ensure the path starts with a slash

        path.gsub(/\/?$/,"")
        # ensure the path doesn't end with a slash

        return URI.escape(path, RESERVED_CHARACTERS) if escape
        path
    end

end
