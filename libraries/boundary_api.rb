##
# Author:: Joe Williams (<j@boundary.com>)
# Cookbook Name:: bprobe
# Library:: boundary_api
#
# Copyright 2011, Boundary
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'json'
require 'uri'
require 'net/https'
require 'base64'

module Boundary
  module API

    def create_meter_request(new_resource)
      begin
        url = build_url(new_resource, :create)
        headers = generate_headers()
        body = {:name => new_resource.name}.to_json

        Chef::Log.info("Creating meter [#{new_resource.name}]")
        response = http_request(:post, url, headers, body)

      rescue Exception => e
        Chef::Log.error("Could not create meter [#{new_resource.name}], failed with #{e}")
      end
    end

    def apply_cloud_tags(new_resource)
      apply_cloud_tags_ec2(new_resource)
      apply_cloud_tags_opsworks(new_resource)
    end

    def apply_cloud_tags_ec2(new_resource)
      if node[:ec2]
        Chef::Log.debug("This meter seems to be on EC2, applying ec2 based tags")

        if node[:ec2][:security_groups].length > 0
          node[:ec2][:security_groups].each do |group|
            apply_an_tag(new_resource, group)
          end
        end

        if node[:ec2][:placement_availability_zone]
          apply_an_tag(new_resource, node[:ec2][:placement_availability_zone])
        end

        if node[:ec2][:instance_type]
          apply_an_tag(new_resource, node[:ec2][:instance_type])
        end
      end
    end

    def apply_cloud_tags_opsworks(new_resource)
      if node[:opsworks]
        Chef::Log.debug("This meter seems to be running AWS OpsWorks, applying OpsWorks based tags")

        if node[:opsworks][:stack]
          if node[:opsworks][:stack][:name]
            apply_an_tag(new_resource, node[:opsworks][:stack][:name])
          end
        end

        if node[:opsworks][:instance]
          if node[:opsworks][:instance][:layers].length > 0
            node[:opsworks][:instance][:layers].each do |layer|
              apply_an_tag(new_resource, layer)
            end
          end
        end

        if node[:opsworks][:applications].length > 0
          node[:opsworks][:applications].each do |app|
            apply_an_tag(new_resource, app["name"])
            apply_an_tag(new_resource, app["application_type"])
          end
        end
      end
    end

    def apply_meter_tags(new_resource)
      Chef::Log.debug("This meter currently has these attribute based tags [#{node[:boundary][:bprobe][:tags]}]")

      tags = node[:boundary][:bprobe][:tags]

      if tags.length > 0
        tags.each do |tag|
          apply_an_tag(new_resource, tag)
        end
      else
        Chef::Log.debug("No meter tags to apply.")
      end
    end

    def apply_an_tag(new_resource, tag)
      begin
        url = build_url(new_resource, :tags)
        headers = generate_headers()

        Chef::Log.info("Applying meter tag [#{tag}]")

        http_request(:put, "#{url}/#{tag}", headers, "")
      rescue Exception => e
        Chef::Log.error("Could not apply meter tag, failed with #{e}")
      end
    end

    def delete_meter_request(new_resource)
      begin
        url = build_url(new_resource, :delete)
        headers = generate_headers()

        Chef::Log.info("Deleting meter [#{new_resource.name}]")
        response = http_request(:delete, url, headers)

      rescue Exception => e
        Chef::Log.error("Could not delete meter [#{new_resource.name}], failed with #{e}")
      end
    end

    def save_meter_id_attribute(new_resource)
      if Chef::Config[:solo]
        Chef::Log.debug("chef-solo run, not attempting to save id attribute.")
      else
        begin
          meter_id = get_meter_id(new_resource)

          if meter_id
            node.set[:boundary][:bprobe][:id] = meter_id
            node.save
          else
            Chef::Log.error("Could not save meter id as node attribute (nil response)!")
          end

        rescue Exception => e
          Chef::Log.error("Could not save meter id as node attribute, failed with #{e}")
        end
      end
    end

    def delete_meter_id_attribute
      if Chef::Config[:solo]
        Chef::Log.debug("chef-solo run, not attempting to delete attribute.")
      else
        begin
          if node[:boundary][:bprobe]
            node[:boundary].delete(:bprobe)
            node.save
          end

          if node.default_attrs[:boundary][:bprobe]
            node.default_attrs[:boundary].delete(:bprobe)
            node.save
          end
        rescue Exception => e
          Chef::Log.error("Could not delete meter id from node attributes, failed with #{e}")
        end
      end
    end

    def generate_headers()
      auth = auth_encode()
      {"Authorization" => "Basic #{auth}", "Content-Type" => "application/json"}
    end

    def auth_encode()
      auth = Base64.encode64("#{node[:boundary][:api][:key]}:").strip
      auth.gsub("\n","")
    end

    def build_url(new_resource, action)
      case action
      when :create
        "https://#{node[:boundary][:api][:hostname]}/#{node[:boundary][:api][:org_id]}/meters"
      when :search
        "https://#{node[:boundary][:api][:hostname]}/#{node[:boundary][:api][:org_id]}/meters?name=#{new_resource.name}"
      when :meter
        meter_id = get_meter_id(new_resource)
        "https://#{node[:boundary][:api][:hostname]}/#{node[:boundary][:api][:org_id]}/meters/#{meter_id}"
      when :certificates
        meter_id = get_meter_id(new_resource)
        "https://#{node[:boundary][:api][:hostname]}/#{node[:boundary][:api][:org_id]}/meters/#{meter_id}"
      when :delete
        meter_id = get_meter_id(new_resource)
        "https://#{node[:boundary][:api][:hostname]}/#{node[:boundary][:api][:org_id]}/meters/#{meter_id}"
      when :tags
        meter_id = get_meter_id(new_resource)
        "https://#{node[:boundary][:api][:hostname]}/#{node[:boundary][:api][:org_id]}/meters/#{meter_id}/tags"
      when :annotate
        "https://#{node[:boundary][:api][:hostname]}/#{node[:boundary][:api][:org_id]}/annotations"
      end
    end

    def meter_exists?(new_resource)
      begin
        url = build_url(new_resource, :search)
        headers = generate_headers()

        response = http_request(:get, url, headers)

        if response
          body = JSON.parse(response.body)

          if body == []
            false
          else
            true
          end
        else
          Chef::Application.fatal!("Could not determine if meter exists (nil response)!")
        end
      rescue Exception => e
        Chef::Application.fatal!("Could not determine if meter exists, failed with #{e}")
      end
    end

    def get_meter_id(new_resource)
      begin
        url = build_url(new_resource, :search)
        headers = generate_headers()

        response = http_request(:get, url, headers)

        if response
          body = JSON.parse(response.body)
          if body[0]
            if body[0]["id"]
              body[0]["id"]
            else
              Chef::Application.fatal!("Could not get meter id (nil response)!")
            end
          else
            Chef::Application.fatal!("Could not get meter id (nil response)!")
          end
        else
          Chef::Application.fatal!("Could not get meter id (nil response)!")
        end

      rescue Exception => e
        Chef::Application.fatal!("Could not get meter id, failed with #{e}")
        nil
      end
    end

    def annotate(new_resource)
      create_opsworks_life_cycle_event_annotation(new_resource)
    end

    def create_opsworks_life_cycle_event_annotation(new_resource)
      if node[:opsworks]
        if node[:opsworks][:activity]
          tags = ["opsworks", "ec2"]

          if node[:opsworks][:stack]
            if node[:opsworks][:stack][:name]
              tags << node[:opsworks][:stack][:name]
            end
          end

          if node[:opsworks][:instance]
            if node[:opsworks][:instance][:layers].length > 0
              node[:opsworks][:instance][:layers].each do |layer|
                tags << layer
              end
            end
          end

          if node[:opsworks][:applications].length > 0
            node[:opsworks][:applications].each do |app|
              tags << app["name"]
              tags << app["application_type"]
            end
          end

          create_annotation(new_resource, "OpsWorks Life Cycle Event on #{node[:fqdn]}", node[:opsworks][:activity], tags)
        end
      end
    end

    def create_annotation(new_resource, type, subtype, tags = [])
      annotation = {
        :type => type,
        :subtype => subtype,
        :start_time => Time.now,
        :end_time => Time.now,
        :tags => tags
      }

      begin
        url = build_url(new_resource, :annotate)
        headers = generate_headers()

        response = http_request(:post, url, headers, annotation.to_json)

        Chef::Log.info("Created a Boundary Annotation @ #{response["location"]}")
      rescue Exception => e
        Chef::Application.fatal!("Could not create annotation due to #{e}!")
      end
    end

    def http_request(method, url, headers, body = nil)
      Chef::Log.debug("Url: #{url}")
      Chef::Log.debug("Headers: #{headers.to_hash.inspect}")
      Chef::Log.debug("Request Body: #{body}")

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      #http.ssl_version = "SSLv3"
      http.ca_file = "#{Chef::Config[:file_cache_path]}/cacert.pem"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER

      case method
      when :get
        req = Net::HTTP::Get.new(uri.request_uri)
      when :post
        req = Net::HTTP::Post.new(uri.request_uri)
        req.body = body
      when :put
        req = Net::HTTP::Put.new(uri.request_uri)
        req.body = body
      when :delete
        req = Net::HTTP::Delete.new(uri.request_uri)
      else
        Chef::Log.error("Unsupported http method (nil response)!")
        nil
      end

      headers.each{|k,v|
        req[k] = v
      }
      response = http.request(req)

      Chef::Log.debug("Response Body: #{response.body}")
      Chef::Log.debug("Status: #{response.code}")

      if bad_response?(method, url, response)
        nil
      else
        response
      end
    end

    def bad_response?(method, url, response)
       case response
       when Net::HTTPSuccess
         false
       else
         true
        Chef::Log.error("Got a #{response.code} for #{method} to #{url}")
       end
    end

  end
end
