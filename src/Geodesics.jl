module Geodesics

    "Earth ellipsoid semi-axes in WGS84"
    const EARTH_R_MAJOR_WGS84 = 6378137.0000
    const EARTH_R_MINOR_WGS84 = 6356752.3142
    "Flattening of the Earth in WGS84"
    const F_WGS84 = (EARTH_R_MAJOR_WGS84 - EARTH_R_MINOR_WGS84)/EARTH_R_MAJOR_WGS84


    """
        local Earth radius in WGS84
    """

    function localEarthRadius(lat,degrees=true)
        if degrees lat = deg2rad(lat) end
        r1 = EARTH_R_MAJOR_WGS84
        r2 = EARTH_R_MINOR_WGS84
        return √(((r1^2 * cos(lat))^2 + (r2^2 * sin(lat))^2 ) / ( (r1 * cos(lat))^2 + (r2 * sin(lat))^2 ))
    end

    """
        angular_distance(lon0, lat0, lon1, lat1, degrees=true; f=F_WGS84) -> Δ

    Return the angular distance between points (`lon0`,`lat0`) and (`lon1`,`lat1`)
    on a flattened sphere.  The default flattening is $F_WGS84.  By default,
    input and output are in degrees, but specify `degrees` as `false` to use radians.
    Use `f=0` to perform computations on a sphere.
    """
    function angular_distance(lon0, lat0, lon1, lat1, degrees::Bool=true; f=F_WGS84)
        if degrees
            lon0, lat0, lon1, lat1 = deg2rad(lon0), deg2rad(lat0), deg2rad(lon1), deg2rad(lat1)
        end
        gcarc, az, baz = inverse(lon0, lat0, lon1, lat1, 1.0, f)
        degrees ? rad2deg(gcarc) : gcarc
    end

    """
        azimuth(lon0, lat0, lon1, lat1, degrees=true, f=F_WGS84)

    Return the azimuth from point (`lon0`,`lat0`) to point (`lon1`,`lat1`) on a
    flattened sphere.  The default flattening is $F_WGS84.  By default,
    input and output are in degrees, but specify `degrees` as `false` to use radians.
    Use `f=0` to perform computations on a sphere.
    """
    function azimuth(lon0::T1, lat0::T2, lon1::T3, lat1::T4, degrees::Bool=true; f=F_WGS84) where {T1,T2,T3,T4}
        # Promote to Float64 at least to avoid error when one of the points is on the pole
        T = promote_type(Float64, T1, T2, T3, T4)
        lon0, lat0, lon1, lat1 = T(lon0), T(lat0), T(lon1), T(lat1)
        if degrees
            lon0, lat0, lon1, lat1 = deg2rad(lon0), deg2rad(lat0), deg2rad(lon1), deg2rad(lat1)
        end
        gcarc, az, baz = inverse(lon0, lat0, lon1, lat1, 1.0, f)
        degrees ? rad2deg(az) : az
    end

    """
        step(lon, lat, azimuth, distance, degrees=true; f=F_WGS84) -> lon′, lat′, backazimuth

    Return the longitude `lon′`, latitude `lat′` and backazimuth `baz` reached by
    travelling an angular `distance` along `azimuth` from the starting point at
    (`lon`,`lat`).  The default flattening is $F_WGS84.  By default,
    input and output are in degrees, but specify `degrees` as `false` to use radians.
    Use `f=0` to perform computations on a sphere.
    """
    function angular_step(lon, lat, azimuth, distance, degrees::Bool=true; f=F_WGS84)
        if degrees
            lon, lat, azimuth, distance = deg2rad(lon), deg2rad(lat), deg2rad(azimuth), deg2rad(distance)
        end
        lon′, lat′, baz = forward(lon, lat, azimuth, distance, 1.0, f)
        if degrees
            rad2deg(lon′), rad2deg(lat′), rad2deg(baz)
        else
            lon′, lat′, baz
        end
    end

    """
        surface_distance(lon0, lat0, lon1, lat1, a, degrees::Bool=false; f=F_WGS84)

    Return the physical distance between points (`lon0`,`lat0`) and (`lon1`,`lat1`) on
    the flattened sphere with flattening `f` and semimajor radius `a`.  Distance is given
    in the same units as `a`.  By default, input angles are in degrees, but specify `degrees`
    as `false` to use radians.  Use `f=0` to perform computations on a sphere.
    """
    function surface_distance(lon0, lat0, lon1, lat1, a, degrees::Bool=true; f=F_WGS84)
        if degrees
            lon0, lat0, lon1, lat1 = deg2rad(lon0), deg2rad(lat0), deg2rad(lon1), deg2rad(lat1)
        end
        distance, az, baz = inverse(lon0, lat0, lon1, lat1, a, f)
        distance
    end

    """
        forward(lon, lat, azimuth, distance, a, f) -> lon′, lat′, backazimuth

    Return the longitude `lon′` and latitude `lat′` and `backazimuth` of a projected
    point, reached by travelling along an `azimuth` for `distance` from an original
    point at (`lon`, `lat`).  Specify the spheroid with the semimajor radius `a` and
    flattening `f`.

    Coordinates and azimuth are in radians.

    Calculations use Vincenty's forward formula [1].

    #### References

    1. Vincenty, T. (1975). "Direct and Inverse Solutions of Geodesics on the Ellipsoid
    with application of nested equations" (PDF). Survey Review. XXIII (176): 88–93.
    doi:10.1179/sre.1975.23.176.88
    """
    function forward(lon, lat, azimuth, distance, a, f)::Tuple{Float64,Float64,Float64}
        abs(lat <= π/2) || throw(ArgumentError("Latitude ($lat) must be in range [-π/2, π/2]"))
        a > 0 || throw(ArgumentError("Semimajor axis ($a) must be positive"))
        abs(f) < 1 || throw(ArgumentError("Magnitude of flattening ($f) must be less than 1"))
        # Calculations are done with Float64s internally as the tolerances are hard-wired
        lambda1, phi1, alpha12, s = Float64(lon), Float64(lat), Float64(azimuth), Float64(distance)
        a, f = Float64(a), Float64(f)
        alpha12 = mod(alpha12, 2π)
        b = a*(1 - f)

        TanU1 = (1 - f)*tan(phi1)
        U1 = atan(TanU1)
        sigma1 = atan( TanU1, cos(alpha12) )
        Sinalpha = cos(U1)*sin(alpha12)
        cosalpha_sq = 1.0 - Sinalpha*Sinalpha

        u2 = cosalpha_sq*(a*a - b*b )/(b*b)
        A = 1.0 + (u2/16384)*(4096 + u2*(-768 + u2*(320 - 175*u2)))
        B = (u2/1024)*(256 + u2*(-128 + u2*(74 - 47*u2)))

        # Starting with the approximation
        sigma = (s/(b*A))

        # Not moving anywhere. We can return the location that was passed in.
        if sigma == 0
            return lambda1, phi1, mod(alpha12 + π, 2π)
        end

        last_sigma = 2*sigma + 2 # something impossible

        # Iterate the following three equations
        # until there is no significant change in sigma
        # two_sigma_m , delta_sigma
        while abs((last_sigma - sigma)/sigma) > 1.0e-9
            global two_sigma_m = 2*sigma1 + sigma
            delta_sigma = B*sin(sigma)*(cos(two_sigma_m) + (B/4)*(cos(sigma)*(-1 + 2*cos(two_sigma_m)^2 - (B/6)*cos(two_sigma_m)*(-3 + 4*sin(sigma)^2)*(-3 + 4*cos(two_sigma_m)^2 ))))
            last_sigma = sigma
            sigma = (s/(b*A)) + delta_sigma
        end

        phi2 = atan((sin(U1)*cos(sigma) + cos(U1)*sin(sigma)*cos(alpha12)),
            ((1-f)*sqrt(Sinalpha^2 + (sin(U1)*sin(sigma) - cos(U1)*cos(sigma)*cos(alpha12))^2)))

        lambda = atan((sin(sigma)*sin(alpha12)),
            (cos(U1)*cos(sigma) - sin(U1)*sin(sigma)*cos(alpha12)))

        C = (f/16)*cosalpha_sq*(4 + f*(4 - 3*cosalpha_sq))

        omega = lambda - (1-C)*f*Sinalpha*(sigma + C*sin(sigma)*(
            cos(two_sigma_m) + C*cos(sigma)*(-1 + 2*cos(two_sigma_m)^2)))

        lambda2 = lambda1 + omega

        alpha21 = atan(Sinalpha, (-sin(U1)*sin(sigma) + cos(U1)*cos(sigma)*cos(alpha12)))
        alpha21 = mod(alpha21 + π, 2π)

        return lambda2, phi2, alpha21
    end

    """
        inverse(lon1, lat1, lon2, lat2, a, f) -> distance, azimuth, backazimuth

    Return the `distance`, `azimuth` and `backazimuth` between two points with longitudes
    `lon1` and `lon2`, and latitudes `lat1` and `lat2`.  Specify the spheroid with the
    semimajor radius `a` and flattening `f`.

    Coordinates and angles are in radians, whilst `distance` is in the same units as `a`.

    Calculations use Vincenty's inverse formula [1].

    #### References

    1. Vincenty, T. (1975). "Direct and Inverse Solutions of Geodesics on the Ellipsoid
    with application of nested equations" (PDF). Survey Review. XXIII (176): 88–93.
    doi:10.1179/sre.1975.23.176.88
    """
    function inverse(lon1, lat1, lon2, lat2, a, f)::Tuple{Float64,Float64,Float64}
        for lat in (lat1, lat2)
            abs(lat <= π/2) || throw(ArgumentError("Latitude ($lat) must be in range [-π/2, π/2]"))
        end
        a > 0 || throw(ArgumentError("Semimajor axis ($a) must be positive"))
        abs(f) < 1 || throw(ArgumentError("Magnitude of flattening ($f) must be less than 1"))
        lambda1, phi1, lambda2, phi2 = Float64(lon1), Float64(lat1), Float64(lon2), Float64(lat2)
        a, f = Float64(a), Float64(f)
        tol = 1.0e-8
        if (abs(phi2 - phi1) < tol) && (abs(lambda2 - lambda1) < tol)
            return 0.0, 0.0, 0.0
        end

        b = a*(1 - f)

        TanU1 = (1 - f)*tan(phi1)
        TanU2 = (1 - f)*tan(phi2)

        U1 = atan(TanU1)
        U2 = atan(TanU2)

        lambda = lambda2 - lambda1
        last_lambda = -4000000.0 # an impossibe value
        omega = lambda

        # Iterate the following equations until there is no significant change in lambda
        alpha, sigma, Sin_sigma, Cos2sigma_m, Cos_sigma, sqr_sin_sigma =
            -999999., -999999., -999999., -999999., -999999., -999999.
        while ((last_lambda < -3000000.0) || (lambda != 0)) &&
                (abs((last_lambda - lambda)/lambda) > 1.0e-9)
            sqr_sin_sigma = (cos(U2)*sin(lambda))^2 +
                            ((cos(U1)*sin(U2) - sin(U1)*cos(U2)*cos(lambda)))^2
            Sin_sigma = sqrt(sqr_sin_sigma)
            Cos_sigma = sin(U1)*sin(U2) + cos(U1)*cos(U2)*cos(lambda)
            sigma = atan(Sin_sigma, Cos_sigma)

            Sin_alpha = cos(U1)*cos(U2)*sin(lambda)/sin(sigma)

            if Sin_alpha >= 1
                Sin_alpha = 1.0
            elseif Sin_alpha <= -1
                Sin_alpha = -1.0
            end

            alpha = asin(Sin_alpha)
            Cos2sigma_m = cos(sigma) - 2*sin(U1)*sin(U2)/cos(alpha)^2
            C = (f/16)*cos(alpha)^2*(4 + f*(4 - 3*cos(alpha)^2))
            last_lambda = lambda
            lambda = omega + (1 - C)*f*sin(alpha)*(sigma +
                C*sin(sigma)*(Cos2sigma_m + C*cos(sigma)*(-1 + 2*Cos2sigma_m^2)))
        end

        u2 = cos(alpha)^2*(a*a - b*b)/(b*b)
        A = 1 + (u2/16384)*(4096 + u2*(-768 + u2*(320 - 175*u2)))
        B = (u2/1024)*(256 + u2*(-128 + u2*(74 - 47*u2)))
        delta_sigma = B*Sin_sigma*(Cos2sigma_m + (B/4)*(
            Cos_sigma*(-1 + 2*Cos2sigma_m^2) -
            (B/6)*Cos2sigma_m*(-3 + 4*sqr_sin_sigma)*(-3 + 4*Cos2sigma_m^2)))
        s = b*A*(sigma - delta_sigma)

        alpha12 = atan((cos(U2)*sin(lambda)), ( cos(U1)*sin(U2) - sin(U1)*cos(U2)*cos(lambda)))
        alpha21 = atan((cos(U1)*sin(lambda)), (-sin(U1)*cos(U2) + cos(U1)*sin(U2)*cos(lambda)))

        alpha12 = mod(alpha12, 2π)
        alpha21 = mod(alpha21 + π, 2π)

        return s, alpha12, alpha21
    end


    """
    find_closest_point_on_segment(p, a, b) -> (lat, lon)

    Trova il punto sul segmento geodetico `a`--`b` più vicino al punto `p`.
    `p`, `a`, e `b` sono punti con campi `lat` e `lon` in gradi.
    Ritorna le coordinate (lat, lon) del punto più vicino.
    """
    function find_closest_point_on_segment(p, a, b)
        # Converte i gradi in radianti per i calcoli
        p_rad = (lat=deg2rad(p.lat), lon=deg2rad(p.lon))
        a_rad = (lat=deg2rad(a.lat), lon=deg2rad(a.lon))
        b_rad = (lat=deg2rad(b.lat), lon=deg2rad(b.lon))

        # Vettori Cartesiani (assumendo una sfera unitaria)
        v_a = (x=cos(a_rad.lat)*cos(a_rad.lon), y=cos(a_rad.lat)*sin(a_rad.lon), z=sin(a_rad.lat))
        v_b = (x=cos(b_rad.lat)*cos(b_rad.lon), y=cos(b_rad.lat)*sin(b_rad.lon), z=sin(b_rad.lat))
        v_p = (x=cos(p_rad.lat)*cos(p_rad.lon), y=cos(p_rad.lat)*sin(p_rad.lon), z=sin(p_rad.lat))

        # Vettore del segmento di rotta
        v_ab = (x=v_b.x-v_a.x, y=v_b.y-v_a.y, z=v_b.z-v_a.z)

        # Proiezione del vettore dal punto 'a' al punto 'p' sul segmento 'ab'
        v_ap = (x=v_p.x-v_a.x, y=v_p.y-v_a.y, z=v_p.z-v_a.z)
        dot_product = v_ap.x*v_ab.x + v_ap.y*v_ab.y + v_ap.z*v_ab.z
        len_sq_ab = v_ab.x^2 + v_ab.y^2 + v_ab.z^2

        # t è il fattore di proiezione. Se 0 <= t <= 1, la proiezione cade nel segmento.
        t = max(0.0, min(1.0, dot_product / len_sq_ab))

        # Calcola le coordinate del punto proiettato
        closest_x = v_a.x + t * v_ab.x
        closest_y = v_a.y + t * v_ab.y
        closest_z = v_a.z + t * v_ab.z

        # Riconverti le coordinate cartesiane in geodetiche (lat, lon)
        final_lon_rad = atan(closest_y, closest_x)
        hyp = sqrt(closest_x^2 + closest_y^2)
        final_lat_rad = atan(closest_z, hyp)

        return (lat=rad2deg(final_lat_rad), lon=rad2deg(final_lon_rad))
    end


end # module
