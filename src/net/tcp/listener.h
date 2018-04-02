#pragma once

#include <functional>
#include <net/endpoint.h>
#include <net/socket.h>
#include <net/poller.h>
#include <net/poller/event.h>
#include <net/poller/io_object.h>
#include <net/log/logging.h>

#if defined _MSC_VER
#	pragma warning(push)
#	pragma warning(disable:4355)
#endif

namespace net { namespace tcp {
	template <class Poller>
	class listener_t
		: public poller::io_object_t<Poller>
		, public poller::event_t
	{
		typedef poller::io_object_t<Poller> base_t;
		typedef poller::event_t event_type;

	public:
		enum stat_t {
			e_idle,
			e_listening,
		};

		listener_t(Poller* poll)
			: base_t(poll, this)
			, stat_(e_idle)
		{
			event_type::sock = socket::retired_fd;
		}

		~listener_t()
		{
			close();
		}

		int open()
		{
			close();

			event_type::sock = socket::open(AF_INET, SOCK_STREAM, IPPROTO_TCP);

			if (event_type::sock == socket::retired_fd)
			{
				NETLOG_ERROR() << "socket("<< event_type::sock << ") socket open error, ec = " << socket::error_no_();
				return -1;
			}

			socket::nonblocking(event_type::sock);
			socket::reuse(event_type::sock);
			int bufsize = 64 * 1024;
			socket::send_buffer(event_type::sock, bufsize);
			socket::recv_buffer(event_type::sock, bufsize);
			return 0;
		}

		virtual void event_accept(net::socket::fd_t fd, const net::endpoint& ep) = 0;

		bool listen(const endpoint& addr, bool rebind)
		{
			assert(stat_ == e_idle);
			NETLOG_INFO() << "socket(" << event_type::sock << ") " << addr.to_string() << " listening";
			int rc = socket::listen(event_type::sock, addr, 0x100, rebind);
			if (rc == 0)
			{
				stat_ = e_listening;
				base_t::set_fd(event_type::sock);
				base_t::set_pollin();
				return true;
			}
			else
			{
				NETLOG_ERROR() << "socket(" << event_type::sock << ") listen error, ec = " << socket::error_no_();
				if (event_type::sock != socket::retired_fd)
				{
					event_close();
				}
				return false;
			}
		}

		void close()
		{
			event_close();
		}

		bool event_in()
		{
			socket::fd_t fd = socket::retired_fd;
			endpoint ep;
			int rc = socket::accept(event_type::sock, fd, ep);
			if (rc == 0)
			{
				event_accept(fd, ep);
				return true;
			}
			else if (rc == -2)
			{
				return true;
			}
			else
			{
				return false;
			}
		}

		bool event_out()
		{
			return true;
		}

		void event_close()
		{
			if (event_type::sock == socket::retired_fd)
			{
				return;
			}

			base_t::rm_fd();
			base_t::cancel_timer();
			socket::close(event_type::sock);
			stat_ = e_idle;
			event_type::sock = socket::retired_fd;
		}

		void event_timer(uint64_t id)
		{ }

		bool is_listening() const
		{
			return stat_ == e_listening;
		}

	protected:
		stat_t stat_;
	};
	typedef listener_t<poller_t> listener;
}}

#if defined _MSC_VER
#	pragma warning(pop)
#endif
