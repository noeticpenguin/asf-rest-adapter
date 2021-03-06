=begin
  ASF-REST-Adapter
  Copyright 2010 Raymond Gao @ http://are4.us

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at
     http://www.apache.org/licenses/LICENSE-2.0
  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
=end

require 'net/https'
require 'net/http'
require 'active_resource'

module Salesforce
  module Rest
    # This is the mother class of all Salesforce REST objects
    # all subclasses need to set the collection name. In ActiveResource convention,
    # pluralized elements has the ending 's'; whereas, in Force.com REST, that 's'
    # is not present.
    # e.g.
    # set_collection_name "User"
    #
    # TODO cannot do "SObject.find(:all)" due to a defect in the ActiveResource framework,
    # see -> ActiveResource::Base line # 885
    #  def instantiate_collection(collection, prefix_options = {})
    #        collection.collect! { |record| instantiate_record(record, prefix_options) }
    #  end
    # As Ruby Hash has not collect! method, only Array,
    # We we get back from Salesforce is a hash
    # <sobject><objectDescribe><.....></objectDescribe><recentItems>...</recentItems></sobject>
    class AsfRest < ActiveResource::Base
      # default REST API server
      self.site = "https://na7.salesforce.com/services/data/v21.0/sobjects"

      # We are mocking OAuth type authentication. In our case, we use the
      # SessionID obtained from the initial SOAP Web Services call - 'login()'
      # OAuth2 is geared toward website to website authentication.
      # In our case, we are the background data interchange between RoR app and
      # Force.com database. Therefore, we use security id.
      # example:
      # connection.set_header("Authorization",  'OAuth 00DA0000000XwIQ!AQIAQD_BX.pdxMz0YBKdkz45PijY0gMxH65JwvV6Yj4.hf44WJYqO9ug7DfhNbnxuO9buhbftiX9Qv5DyBLHauaJhqTh79vi')

      # self.abstract_class = true

      # Setup the adapter
      def self.setup(oauth_token, base_url, api_version)
        @@oauth_token = oauth_token
        @@base_url = base_url
        @@api_version = "v21.0"  #take a dynamic api server version
        @@rest_svr_url = base_url + "/services/data/#{api_version}/sobjects"
        @@ssl_port = 443  # TODO, a dynamic SSL port

        self.site = "https://" +  @@rest_svr_url
        connection.set_header("Authorization", "OAuth " + @@oauth_token)
        # either application/xml or application/json
        self.format = :json
 
        return self
      end

      #Save the Object, Note: there is an inconsistency between the Salesforce REST
      #JSON create object, which is just {"Name1":"value1","Name2":"value2"}
      #where as the 'save' method of the ActiveResource produces a JSON of
      #{"Object Name":{"Name1":"value1","Name2":"value2"}}.
      #The Extra/missing 'Object Name' causes this to break.
      #When this consistency is resolved, this method should be removed.
      def save
        data = ActiveSupport::JSON::encode(attributes)
        http = Net::HTTP.new(@@base_url, @@ssl_port)
        http.use_ssl = true        
        class_name = self.class.name.gsub(/\S+::/mi, "")
        #puts "Class name is: " + class_name
        path = "/services/data/#{@@api_version}/sobjects/#{class_name}/"
        headers = {
          'Authorization' => "OAuth "+ @@oauth_token,
          "content-Type" => 'application/json',
        }
        resp = http.post(path, data, headers)
        #self.find(ActiveSupport::JSON.decode(resp.body)["id"])
        return resp
      end
      
      #Again the delete feature from ActiveResource does not work out of the box.
      #Using custom delete function
      def self.delete(id)
        http = Net::HTTP.new(@@base_url, @@ssl_port)
        http.use_ssl = true
        class_name = self.name.gsub(/\S+::/mi, "")
        path = "/services/data/#{@@api_version}/sobjects/#{class_name}/#{id}"
        headers = {
          'Authorization' => "OAuth "+ @@oauth_token
        }
        resp = http.delete(path, headers)
        return resp
      end

      #Custom object with PATCH method
      class TrackRequest < Net::HTTPRequest
        METHOD = 'PATCH'
        REQUEST_HAS_BODY = true
        RESPONSE_HAS_BODY = true
      end

      # Memcached version of the get_detail_info() method
      def self.xget_detail_info()
        @@memcache_id =  self.name + "/describe"
        if Rails.cache.exist? @@memcache_id
          binobj = Rails.cache.read(@@memcache_id)
          # deserialize from Json
          return binobj
        else
          obj = self.get_detail_info()
          # Save a Json, Marshal.dump or :raw does not work
          Rails.cache.write(@@memcache_id, obj.to_json)
          return obj
        end
      end      
      #get detailed info about this object
      def self.get_detail_info()
        http = Net::HTTP.new(@@base_url, @@ssl_port)
        http.use_ssl = true
        class_name = self.name.gsub(/\S+::/mi, "")
        path = "/services/data/#{@@api_version}/sobjects/#{class_name}/describe"
        headers = {
          'Authorization' => "OAuth " + @@oauth_token,
          "content-Type" => 'application/json',
        }
        resp = http.get(path,headers)
        if resp.code != "200"
          message = ActiveSupport::JSON.decode(resp.body)[0]["message"]
          Salesforce::Rest::ErrorManager.raise_error("HTTP code " + resp.code + ": " + message, resp.code)
        end
        return resp.body
      end

      # Memcached version of the get_meta_data() method
      def self.xget_meta_data()
        @@memcache_id =  self.name + "/meta_data"
        if Rails.cache.exist? @@memcache_id
          binobj = Rails.cache.read(@@memcache_id)
          # deserialize from Json
          obj = Net::HTTP.new.from_json(binobj)
          return obj
        else
          obj = self.get_meta_data()
          # Save a Json, Marshal.dump or :raw does not work
          Rails.cache.write(@@memcache_id, obj)
          return obj
        end
      end
      #get meta data about this object
      def self.get_meta_data()
        http = Net::HTTP.new(@@base_url, @@ssl_port)
        http.use_ssl = true
        class_name = self.name.gsub(/\S+::/mi, "")
        path = "/services/data/#{@@api_version}/sobjects/#{class_name}/"
        headers = {
          'Authorization' => "OAuth "+ @@oauth_token,
          "content-Type" => 'application/json',
        }
        resp = http.get(path,headers)
        return resp
      end


      #Update an object
      def self.update(id, serialized_json)
        #Again the delete feature from ActiveResource does not work out of the box.
        #Providing a custom update function
        http = Net::HTTP.new(@@base_url, @@ssl_port)
        http.use_ssl = true
        class_name = self.name.gsub(/\S+::/mi, "")        
        path = "/services/data/#{@@api_version}/sobjects/#{class_name}/#{id}"
        headers = {
          'Authorization' => "OAuth "+ @@oauth_token,
          "content-Type" => 'application/json',
        }
        code = serialized_json
        #   format -> Net::HTTPGenericRequest.new(m, reqbody, resbody, path, initheader)
        req = Net::HTTPGenericRequest.new("PATCH", true, true, path, headers)

        resp = http.request(req, code) { |response|  }
        return resp
      end


      # Memcached version of the describe_global() method
      def self.xdescribe_global()
        @@memcache_id =  self.name + "/describe_global"
        if Rails.cache.exist? @@memcache_id
          binobj = Rails.cache.read(@@memcache_id)
          # deserialize from Json
          obj = Net::HTTPResponse.new.from_json(binobj)
          return obj
        else
          obj = self.describe_global()
          # Save a Json, Marshal.dump or :raw does not work
          Rails.cache.write(@@memcache_id, obj)
          return obj
        end
      end
      # Describe global of the REST server
      def self.describe_global()
        http = Net::HTTP.new(@@base_url, @@ssl_port)
        http.use_ssl = true
        path = "/services/data/#{@@api_version}/sobjects/"

        headers = {
          'Authorization' => "OAuth "+ @@oauth_token
        }
        # GET request -> so the host can set his cookies        
        resp = http.get(path, headers)
        return resp
      end


       # Memcached version of the list_available_resources() method
      def self.xlist_available_resources()
        @@memcache_id =  self.name + "/list_available_resources"
        if Rails.cache.exist? @@memcache_id
          binobj = Rails.cache.read(@@memcache_id)
          # deserialize from Json
          obj = Net::HTTP.new.from_json(binobj)
          return obj
        else
          obj = self.list_available_resources()
          # Save a Json, Marshal.dump or :raw does not work
          Rails.cache.write(@@memcache_id, obj)
          return obj
        end
      end
      # get resources available on this REST server
      def self.list_available_resources()
        http = Net::HTTP.new(@@base_url, @@ssl_port)
        http.use_ssl = true
        path = "/services/data/#{@@api_version}/"
        headers = {
          'Authorization' => "OAuth "+ @@oauth_token
        }
        resp = http.get(path, headers)
        return resp
      end


       # Memcached version of the get_version() method
      def self.xget_version()
        @@memcache_id =  self.name + "/get_version"
        if Rails.cache.exist? @@memcache_id
          binobj = Rails.cache.read(@@memcache_id)
          # deserialize from Json
          obj = Net::HTTP.new.from_json(binobj)
          return obj
        else
          obj = self.get_version()
          # Save a Json, Marshal.dump or :raw does not work
          Rails.cache.write(@@memcache_id, obj)
          return obj
        end
      end
      # get version of the REST API Server
      def self.get_version()
        http = Net::HTTP.new(@@base_url, @@ssl_port)
        http.use_ssl = true
        path = '/services/data/'
        headers = {
          'Authorization' => "OAuth "+ @@oauth_token
        }
        resp = http.get(path, headers)
        return resp
      end

       # Memcached version of the run_soql() method
      def self.xrun_soql(query)
        @@memcache_id =  self.name + "/run_soql?#{query}"
        if Rails.cache.exist? @@memcache_id
          binobj = Rails.cache.read(@@memcache_id)
          # deserialize from Json
          obj = Net::HTTP.new.from_json(binobj)
          return obj
        else
          obj = self.run_soql(query)
          # Save a Json, Marshal.dump or :raw does not work
          Rails.cache.write(@@memcache_id, obj)
          return obj
        end
      end
      # Run SOQL
      def self.run_soql(query)
        http = Net::HTTP.new(@@base_url, @@ssl_port)
        http.use_ssl = true
        path = "/services/data/#{@@api_version}/query?q=#{query}"
        headers = {
          'Authorization' => "OAuth "+ @@oauth_token
        }
        resp = http.get(path, headers)
        return resp
      end

       # Memcached version of the run_sosl() method
      def self.xrun_sosl(search)
        @@memcache_id =  self.name + "/run_sosl?#{search}"
        if Rails.cache.exist? @@memcache_id
          binobj = Rails.cache.read(@@memcache_id)
          # deserialize from Json
          obj = Net::HTTP.new.from_json(binobj)
          return obj
        else
          obj = self.run_sosl(search)
          # Save a Json, Marshal.dump or :raw does not work
          Rails.cache.write(@@memcache_id, obj)
          return obj
        end
      end
      # Run SOSL
      def self.run_sosl(search)
        http = Net::HTTP.new(@@base_url, @@ssl_port)
        http.use_ssl = true
        path = "/services/data/#{@@api_version}/search/?q=#{search}"

        headers = {
          'Authorization' => "OAuth "+ @@oauth_token
        }
        resp = http.get(path, headers)

        return resp
      end

      # xfind is the cached version of the ActiveReources Find method. You will
      # see the speed improvement with memcache turned on.
      def self.xfind(*arguments)
        if Rails.cache.exist? arguments
          binobj = Rails.cache.read(arguments)
          # deserialize from Json
          obj = self.name.constantize.new.from_json(binobj)
          return obj
        else
          obj = self.find(arguments)
          # Save a Json, Marshal.dump or :raw does not work
          Rails.cache.write(arguments, obj.to_json())
          return obj
        end
      end
      
      # Used for removing the .xml and .json extensions at the end of the URL link.
      class << self
        # removing http://....../UID.xml
        def element_path(id, prefix_options = {}, query_options = nil)
          prefix_options, query_options = split_options(prefix_options) if query_options.nil?
          "#{prefix(prefix_options)}#{collection_name}/#{id}#{query_string(query_options)}"
        end
        # removing http://....../UID.json
        def collection_path(prefix_options = {}, query_options = nil)
          prefix_options, query_options = split_options(prefix_options) if query_options.nil?
          "#{prefix(prefix_options)}#{collection_name}#{query_string(query_options)}"
        end
      end
    end
  end
end